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
          auth: {module(), keyword()} | nil,
          pending_peer_calls: %{binary() => {reference(), pid()}}
        }

  @impl WebSock
  def init(opts) do
    state = %{
      router: Map.fetch!(opts, :router),
      handshake_opts: Map.get(opts, :handshake_opts, []),
      context: Map.get(opts, :context, %{}),
      auth: Map.get(opts, :auth),
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
    case Frame.decode(data) do
      {:ok, frame} ->
        case frame.type do
          type when type in [:reply, :error] ->
            handle_peer_response(frame, state)

          _ ->
            dispatch_frame(frame, state, conn)
        end

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

  def handle_info({:stream_chunk, frame}, state) do
    {:push, {:binary, Frame.encode!(frame)}, state}
  end

  def handle_info({:stream_end, frame}, state) do
    {:push, {:binary, Frame.encode!(frame)}, state}
  end

  def handle_info({:stream_error, frame}, state) do
    {:push, {:binary, Frame.encode!(frame)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp negotiate(%{router: router} = state, payload) do
    local = Handshake.build(state.handshake_opts || [])

    with {:ok, session} <- Handshake.negotiate(local, payload),
         {:ok, auth_context} <- authenticate(state.auth, payload) do
      # Create peer handle for bidirectional RPC
      peer = Peer.new(handler_pid: self(), timeout: 5_000)

      # Merge base context, auth context, and peer
      context =
        state
        |> Map.get(:context, %{})
        |> Map.merge(auth_context)
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
    end
  end

  defp authenticate(nil, _payload), do: {:ok, %{}}

  defp authenticate({auth_module, auth_opts}, payload) do
    # Payload has atom keys, meta has string keys (from client)
    credentials = get_in(payload, [:meta, "auth"])

    case auth_module.authenticate(credentials, auth_opts) do
      {:ok, context} when is_map(context) ->
        {:ok, context}

      {:error, reason, detail} ->
        {:error, {:authentication_failed, reason, detail}}

      {:error, reason} ->
        {:error, {:authentication_failed, reason}}

      other ->
        {:error, {:invalid_auth_response, other}}
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
