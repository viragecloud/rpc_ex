defmodule RpcEx.Server.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  alias RpcEx.Peer
  alias RpcEx.Protocol.{Frame, Handshake}
  alias RpcEx.Server.Connection

  @type state :: %{
          router: module(),
          handshake_opts: keyword(),
          negotiated?: boolean(),
          connection: Connection.t() | nil,
          context: map(),
          pending_peer_calls: %{binary() => {reference(), pid()}}
        }

  @impl WebSock
  def init(opts) do
    state = %{
      router: Map.fetch!(opts, :router),
      handshake_opts: Map.get(opts, :handshake_opts, []),
      context: Map.get(opts, :context, %{}),
      negotiated?: false,
      connection: nil,
      pending_peer_calls: %{}
    }

    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, opcode: :binary}, %{negotiated?: false} = state) do
    with {:ok, %Frame{type: :hello, payload: payload}} <- Frame.decode(data),
         {:ok, reply, new_state} <- negotiate(state, payload) do
      {:push, {:binary, Frame.encode!(reply)}, new_state}
    else
      {:ok, %Frame{} = frame} ->
        {:stop, {:error, {:unexpected_frame, frame.type}}, {1002, "unexpected_frame"}, state}

      {:error, reason} ->
        {:stop, {:error, {:handshake_failed, reason}}, {1002, reason_to_binary(reason)}, state}
    end
  end

  def handle_in({data, opcode: :binary}, %{negotiated?: true, connection: conn} = state) do
    with {:ok, frame} <- Frame.decode(data) do
      case frame.type do
        type when type in [:reply, :error] ->
          handle_peer_response(frame, state)

        _ ->
          dispatch_frame(frame, state, conn)
      end
    else
      {:error, reason} ->
        {:stop, {:error, {:invalid_frame, reason}}, {1003, reason_to_binary(reason)}, state}
    end
  end

  def handle_in({_data, opcode: :text}, state) do
    {:stop, {:error, :unsupported_opcode}, {1003, "text_frames_not_supported"}, state}
  end

  @impl WebSock
  def handle_control({_data, _opts}, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:handler_result, :call, action, _new_ctx}, state) do
    # Handler completed asynchronously, send the response
    case action do
      {:reply, frame} ->
        {:push, {:binary, Frame.encode!(frame)}, state}

      {:push, frame} ->
        {:push, {:binary, Frame.encode!(frame)}, state}

      :noreply ->
        {:ok, state}
    end
  end

  def handle_info({:peer_call, ref, frame, from_pid}, state) do
    %Frame{payload: %{msg_id: msg_id}} = frame
    pending = Map.put(state.pending_peer_calls, msg_id, {ref, from_pid})
    {:push, {:binary, Frame.encode!(frame)}, %{state | pending_peer_calls: pending}}
  end

  def handle_info({:peer_cast, frame}, state) do
    {:push, {:binary, Frame.encode!(frame)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp negotiate(%{router: router} = state, payload) do
    local = Handshake.build(state.handshake_opts || [])

    case Handshake.negotiate(local, payload) do
      {:ok, session} ->
        # Create peer handle for bidirectional RPC
        peer = Peer.new(handler_pid: self(), timeout: 5_000)

        # Inject peer into context so handlers can call back
        context =
          state
          |> Map.get(:context, %{})
          |> Map.put(:peer, peer)

        connection =
          Connection.new(
            router: router,
            session: session,
            context: context
          )

        reply =
          Frame.new(:welcome, %{
            protocol_version: session.protocol_version,
            compression: session.compression,
            encoding: session.encoding,
            capabilities: session.local_capabilities,
            meta: session.meta
          })

        {:ok, reply, %{state | negotiated?: true, connection: connection}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_frame(frame, state, conn) do
    case Connection.handle_frame(frame, conn) do
      {:async, new_conn} ->
        # Handler will send result asynchronously
        {:ok, %{state | connection: new_conn}}

      {:reply, reply_frame, new_conn} ->
        {:push, {:binary, Frame.encode!(reply_frame)}, %{state | connection: new_conn}}

      {:push, push_frame, new_conn} ->
        {:push, {:binary, Frame.encode!(push_frame)}, %{state | connection: new_conn}}

      {:noreply, new_conn} ->
        {:ok, %{state | connection: new_conn}}
    end
  end

  defp handle_peer_response(%Frame{type: :reply, payload: payload}, state) do
    %{msg_id: msg_id, result: result} = payload
    meta = Map.get(payload, :meta, %{})

    case Map.pop(state.pending_peer_calls, msg_id) do
      {nil, _pending} ->
        # Unexpected reply, ignore
        {:ok, state}

      {{ref, from_pid}, pending} ->
        send(from_pid, {:peer_reply, ref, {:ok, result, meta}})
        {:ok, %{state | pending_peer_calls: pending}}
    end
  end

  defp handle_peer_response(%Frame{type: :error, payload: payload}, state) do
    %{msg_id: msg_id, reason: reason} = payload
    detail = Map.get(payload, :detail)

    case Map.pop(state.pending_peer_calls, msg_id) do
      {nil, _pending} ->
        # Unexpected error, ignore
        {:ok, state}

      {{ref, from_pid}, pending} ->
        send(from_pid, {:peer_reply, ref, {:error, {reason, detail}}})
        {:ok, %{state | pending_peer_calls: pending}}
    end
  end

  defp reason_to_binary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_binary(reason) when is_binary(reason), do: reason
  defp reason_to_binary(reason), do: inspect(reason)
end
