defmodule RpcEx.Server.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  require Logger

  alias Horde.Registry
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
          pending_peer_calls: %{binary() => {reference(), pid()}},
          horde_opts: map() | nil,
          horde_registry: atom() | nil,
          horde_key: term() | nil,
          horde_meta: map()
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
      pending_peer_calls: %{},
      horde_opts: normalize_horde_opts(Map.get(opts, :horde)),
      horde_registry: nil,
      horde_key: nil,
      horde_meta: %{}
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

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    update_horde_status(state, :disconnected)
    :ok
  end

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

      new_state =
        state
        |> Map.put(:negotiated?, true)
        |> Map.put(:connection, connection)
        |> register_with_horde(session, payload)

      {:ok, reply, new_state}
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

  defp normalize_horde_opts(nil), do: nil
  defp normalize_horde_opts(%{} = opts), do: opts
  defp normalize_horde_opts(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp normalize_horde_opts(_), do: nil

  defp register_with_horde(%{horde_opts: nil} = state, _session, _payload), do: state

  defp register_with_horde(
         %{horde_opts: %{registry: registry, key: key} = opts} = state,
         session,
         payload
       )
       when is_atom(registry) do
    base_meta =
      opts
      |> Map.get(:meta, %{})
      |> Map.new()
      |> Map.merge(session_horde_meta(session))
      |> maybe_put(:client_meta, Map.get(payload, :meta))
      |> maybe_put(:router, state.router)
      |> Map.put(:node, node())

    case safe_register(registry, key, Map.put(base_meta, :status, :ready)) do
      {:ok, _pid} ->
        %{state | horde_registry: registry, horde_key: key, horde_meta: base_meta}
        |> update_horde_status(:ready)

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "Horde registry already has connection entry for #{inspect(key)} (#{inspect(pid)})"
        )

        %{state | horde_registry: registry, horde_key: key, horde_meta: base_meta}
        |> update_horde_status(:ready)

      {:error, reason} ->
        Logger.warning("Failed to register server connection with Horde: #{inspect(reason)}")
        state
    end
  rescue
    _ -> state
  end

  defp register_with_horde(state, _session, _payload), do: state

  defp safe_register(registry, key, value) do
    Registry.register(registry, key, value)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp update_horde_status(state, status, extra \\ %{})
  defp update_horde_status(%{horde_registry: nil} = state, _status, _extra), do: state

  defp update_horde_status(state, status, extra) do
    meta =
      state.horde_meta
      |> Map.merge(extra)
      |> Map.put(:status, status)
      |> Map.put_new(:node, node())
      |> compact_meta()

    case Registry.update_value(state.horde_registry, state.horde_key, fn _ -> meta end) do
      {:error, _} -> state
      _ -> state
    end
  rescue
    _ -> state
  end

  defp session_horde_meta(session) do
    %{}
    |> maybe_put(:protocol_version, Map.get(session, :protocol_version))
    |> maybe_put(:compression, Map.get(session, :compression))
    |> maybe_put(:encoding, Map.get(session, :encoding))
    |> maybe_put(:capabilities, Map.get(session, :remote_capabilities))
    |> maybe_put(:session_meta, Map.get(session, :meta))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_meta(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp reason_to_binary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_binary(reason) when is_binary(reason), do: reason
  defp reason_to_binary(reason), do: inspect(reason)
end
