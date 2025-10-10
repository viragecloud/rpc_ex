defmodule RpcEx.Client do
  @moduledoc """
  Mint-based RPC client that manages a WebSocket session to a remote peer.

  Responsibilities:
  * Establish a Mint.WebSocket connection and negotiate the RpcEx ETF protocol.
  * Dispatch calls & casts, correlate replies, and enforce per-call timeouts.
  * Forward inbound server-initiated RPC messages through the router executor.
  * Support optional reflection (`discover/2`) and server notifications.
  """

  use GenServer

  require Logger

  alias Mint.{HTTP, WebSocket}
  alias RpcEx.Client.Connection
  alias RpcEx.Protocol.{Frame, Handshake}

  @subprotocol "rpc_ex.etf.v1"

  @type option ::
          {:name, GenServer.name()}
          | {:url, String.t()}
          | {:router, module()}
          | {:timeout, non_neg_integer()}
          | {:handshake, keyword()}
          | {:context, map()}
          | {:telemetry_prefix, [atom()]}
          | {:transport_opts, keyword()}
          | {:websocket_opts, keyword()}

  @type call_option ::
          {:timeout, non_neg_integer()}
          | {:args, term()}
          | {:meta, map()}

  @typedoc "Opaque reference for async call tracking."
  @type call_ref :: binary()

  ## Public API

  @doc """
  Starts the client.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Child specification for supervision trees.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Performs a synchronous RPC call to the connected server.
  """
  @spec call(GenServer.name(), RpcEx.route(), keyword()) ::
          {:ok, term(), map()} | {:error, term()}
  def call(client, route, opts \\ []) do
    GenServer.call(client, {:call, route, opts}, Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  Dispatches a fire-and-forget cast.
  """
  @spec cast(GenServer.name(), RpcEx.route(), keyword()) :: :ok | {:error, term()}
  def cast(client, route, opts \\ []) do
    GenServer.call(client, {:cast, route, opts})
  end

  @doc """
  Requests discovery metadata from the server.
  """
  @spec discover(GenServer.name(), keyword()) ::
          {:ok, list(), map()} | {:error, term()}
  def discover(client, opts \\ []) do
    GenServer.call(client, {:discover, opts})
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    router = Keyword.get(opts, :router)
    handshake_opts = Keyword.get(opts, :handshake, [])
    timeout = Keyword.get(opts, :timeout, 5_000)
    context = Keyword.get(opts, :context, %{})
    transport_opts = Keyword.get(opts, :transport_opts, [])
    websocket_opts = Keyword.get(opts, :websocket_opts, compress: false)

    uri = URI.parse(url)
    scheme = normalize_scheme(uri.scheme)
    host = uri.host || raise ArgumentError, "url must include host"
    port = uri.port || default_port(scheme)
    path = normalize_path(uri.path, uri.query)

    local_handshake = Handshake.build(handshake_opts)

    handshake_payload =
      local_handshake
      |> Map.from_struct()
      |> Map.put(:meta, Map.get(local_handshake, :meta, %{}))

    state = %{
      conn: nil,
      websocket: nil,
      request_ref: nil,
      status: :connecting,
      router: router,
      connection: Connection.new(router: router, session: %{}, context: context),
      pending: %{},
      timeout: timeout,
      uri: uri,
      scheme: scheme,
      host: host,
      port: port,
      path: path,
      transport_opts: transport_opts,
      websocket_opts: websocket_opts,
      local_handshake_struct: local_handshake,
      local_handshake_payload: handshake_payload,
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [:rpc_ex, :client]),
      session: %{},
      reconnect: Keyword.get(opts, :reconnect, []),
      buffer: %{},
      awaiting_welcome?: false,
      upgrade_status: nil,
      upgrade_headers: nil,
      upgrade_done: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case establish_connection(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call({:call, route, opts}, from, %{status: :ready} = state) do
    args = Keyword.get(opts, :args, %{})
    timeout = Keyword.get(opts, :timeout, state.timeout)
    meta = Keyword.get(opts, :meta)
    msg_id = generate_id()

    payload = %{
      msg_id: msg_id,
      route: route,
      args: args,
      timeout_ms: timeout,
      meta: meta
    }

    with {:ok, state} <- send_frame(Frame.new(:call, payload), state) do
      timer =
        if timeout && timeout != :infinity do
          Process.send_after(self(), {:pending_timeout, msg_id}, timeout)
        end

      pending = Map.put(state.pending, msg_id, %{from: from, timer: timer, type: :call})
      {:noreply, %{state | pending: pending}}
    else
      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, _route, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:cast, route, opts}, _from, %{status: :ready} = state) do
    args = Keyword.get(opts, :args, %{})
    meta = Keyword.get(opts, :meta)

    payload = %{
      route: route,
      args: args,
      meta: meta
    }

    case send_frame(Frame.new(:cast, payload), state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discover, opts}, from, %{status: :ready} = state) do
    scope = Keyword.get(opts, :scope, :all)
    msg_id = generate_id()
    payload = %{msg_id: msg_id, scope: scope}

    with {:ok, state} <- send_frame(Frame.new(:discover, payload), state) do
      pending = Map.put(state.pending, msg_id, %{from: from, timer: nil, type: :discover})
      {:noreply, %{state | pending: pending}}
    else
      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discover, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:cast, _route, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl GenServer
  def handle_info({:pending_timeout, msg_id}, state) do
    case Map.pop(state.pending, msg_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl GenServer
  def handle_info(_message, %{conn: nil} = state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, responses} ->
        Logger.error("RPC client connection error: #{inspect(reason)} responses=#{inspect(responses)}")
        {:stop, {:error, reason}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  catch
    kind, reason ->
      {:stop, {kind, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.conn && state.websocket && state.request_ref do
      with {:ok, _websocket, data} <- WebSocket.encode(state.websocket, {:close, 1000, ""}),
           {:ok, _conn} <- WebSocket.stream_request_body(state.conn, state.request_ref, data) do
        :ok
      else
        _ -> :ok
      end
    end

    :ok
  end

  ## Internal helpers

  defp establish_connection(state) do
    with {:ok, conn} <- HTTP.connect(state.scheme, state.host, state.port, state.transport_opts),
         {:ok, conn, ref} <-
           WebSocket.upgrade(
             ws_scheme(state.scheme),
             conn,
             state.path,
             [
               {"host", host_header(state.host, state.port, state.scheme)},
               {"sec-websocket-protocol", @subprotocol}
             ],
             Keyword.put_new(state.websocket_opts, :subprotocols, [@subprotocol])
           ) do
      {:ok,
       %{
         state
         | conn: conn,
           request_ref: ref,
           status: :awaiting_upgrade
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_responses(responses, state) do
    if state.status == :awaiting_upgrade do
      Logger.debug("upgrade responses: #{inspect(responses)}")
    end
    responses
    |> Enum.reduce_while({:noreply, state}, fn
      {:status, ref, status}, {:noreply, state} when ref == state.request_ref ->
        {:cont, {:noreply, %{state | upgrade_status: status}}}

      {:headers, ref, headers}, {:noreply, state} when ref == state.request_ref ->
        {:cont, {:noreply, %{state | upgrade_headers: headers}}}

      {:data, ref, data}, {:noreply, %{websocket: websocket} = state}
      when ref == state.request_ref ->
        case WebSocket.stream(websocket, data) do
          {:ok, websocket, frames} ->
            state = %{state | websocket: websocket}

            case handle_ws_frames(frames, state) do
              {:ok, new_state} -> {:cont, {:noreply, new_state}}
              {:stop, reason, new_state} -> {:halt, {:stop, reason, new_state}}
            end

          {:error, websocket, reason} ->
            {:halt, {:stop, reason, %{state | websocket: websocket}}}
        end

      {:done, ref}, {:noreply, state} when ref == state.request_ref ->
        {:cont, {:noreply, %{state | upgrade_done: true}}}

      _response, {:noreply, state} ->
        {:cont, {:noreply, state}}
    end)
    |> maybe_finalize_upgrade()
    |> normalize_response()
  end

  defp handle_ws_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, acc_state} ->
      case frame do
        {:binary, data} ->
          handle_binary_frame(data, acc_state)

        {:text, _data} ->
          {:halt, {:stop, :unexpected_text_frame, acc_state}}

        {:ping, data} ->
          case send_ws_frame({:pong, data}, acc_state) do
            {:ok, new_state} -> {:cont, {:ok, new_state}}
            {:error, reason, new_state} -> {:halt, {:stop, reason, new_state}}
          end

        {:close, code, data} ->
          {:halt, {:stop, {:remote_close, {code, data}}, acc_state}}

        _ ->
          {:cont, {:ok, acc_state}}
      end
    end)
  end

  defp handle_binary_frame(data, state) do
    case Frame.decode(data) do
      {:ok, %Frame{type: :welcome, payload: payload}} ->
        handle_welcome(payload, state)

      {:ok, %Frame{type: :reply, payload: payload}} ->
        {:ok, handle_reply(payload, state)}

      {:ok, %Frame{type: :error, payload: payload}} ->
        {:ok, handle_error_reply(payload, state)}

      {:ok, %Frame{type: :discover_reply, payload: payload}} ->
        {:ok, handle_discover_reply(payload, state)}

      {:ok, %Frame{type: type} = frame} when type in [:call, :cast, :discover] ->
        handle_inbound_rpc(frame, state)

      {:ok, %Frame{type: :notify, payload: payload}} ->
        Logger.debug("received notify #{inspect(payload)}")
        {:ok, state}

      {:error, reason} ->
        {:halt, {:stop, {:decode_error, reason}, state}}
    end
  end

  defp handle_welcome(payload, state) do
    case Handshake.negotiate(state.local_handshake_struct, payload) do
      {:ok, session} ->
        connection =
          state.connection
          |> Connection.put_router(state.router)
          |> Map.replace!(:session, session)

        {:ok,
         %{
           state
           | status: :ready,
             awaiting_welcome?: false,
             session: session,
             connection: connection
         }}

      {:error, reason} ->
        {:halt, {:stop, {:handshake_failed, reason}, state}}
    end
  end

  defp handle_reply(%{msg_id: msg_id} = payload, state) do
    with {%{from: from, timer: timer}, pending} <- Map.pop(state.pending, msg_id) do
      if timer, do: Process.cancel_timer(timer)
      result = Map.get(payload, :result)
      meta = Map.get(payload, :meta, %{})
      GenServer.reply(from, {:ok, result, meta})
      %{state | pending: pending}
    else
      _ -> state
    end
  end

  defp handle_error_reply(%{msg_id: msg_id} = payload, state) do
    with {%{from: from, timer: timer}, pending} <- Map.pop(state.pending, msg_id) do
      if timer, do: Process.cancel_timer(timer)
      reason = Map.get(payload, :reason, :unknown)
      detail = Map.get(payload, :detail)
      GenServer.reply(from, {:error, {reason, detail}})
      %{state | pending: pending}
    else
      _ -> state
    end
  end

  defp handle_discover_reply(%{msg_id: msg_id} = payload, state) do
    with {%{from: from}, pending} <- Map.pop(state.pending, msg_id) do
      entries = Map.get(payload, :entries, [])
      meta = Map.get(payload, :meta, %{})
      GenServer.reply(from, {:ok, entries, meta})
      %{state | pending: pending}
    else
      _ -> state
    end
  end

  defp handle_inbound_rpc(frame, %{connection: connection} = state) do
    case Connection.handle_frame(frame, connection) do
      {:reply, reply_frame, new_conn} ->
        case send_frame(reply_frame, %{state | connection: new_conn}) do
          {:ok, new_state} -> {:ok, new_state}
          {:error, reason, new_state} -> {:halt, {:stop, reason, new_state}}
        end

      {:push, push_frame, new_conn} ->
        case send_frame(push_frame, %{state | connection: new_conn}) do
          {:ok, new_state} -> {:ok, new_state}
          {:error, reason, new_state} -> {:halt, {:stop, reason, new_state}}
        end

      {:noreply, new_conn} ->
        {:ok, %{state | connection: new_conn}}
    end
  end

  defp send_frame(_frame, %{websocket: nil} = state) do
    {:error, :not_ready, state}
  end

  defp send_frame(%Frame{} = frame, state) do
    binary = Frame.encode!(frame)
    send_ws_frame({:binary, binary}, state)
  end

  defp send_ws_frame(frame_tuple, %{websocket: websocket, conn: conn, request_ref: ref} = state) do
    with {:ok, websocket, data} <- WebSocket.encode(websocket, frame_tuple),
         {:ok, conn} <- WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}

      {:error, conn, reason} ->
        {:error, reason, %{state | conn: conn}}
    end
  end

  defp normalize_scheme("ws"), do: :http
  defp normalize_scheme("wss"), do: :https
  defp normalize_scheme("http"), do: :http
  defp normalize_scheme("https"), do: :https
  defp normalize_scheme(nil), do: :http

  defp normalize_scheme(other) do
    raise ArgumentError, "unsupported scheme #{inspect(other)}"
  end

  defp ws_scheme(:https), do: :wss
  defp ws_scheme(:http), do: :ws
  defp ws_scheme(:wss), do: :wss
  defp ws_scheme(:ws), do: :ws

  defp normalize_path(nil, nil), do: "/"
  defp normalize_path("", nil), do: "/"
  defp normalize_path(path, nil), do: path
  defp normalize_path(path, query), do: "#{path}?#{query}"

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp host_header(host, port, scheme) do
    default = default_port(scheme)
    if port == default, do: host, else: "#{host}:#{port}"
  end

  defp complete_upgrade(%{status: :awaiting_upgrade, upgrade_headers: headers} = state, ref)
       when is_list(headers) do
    status = state.upgrade_status || 101

    try do
      case WebSocket.new(state.conn, ref, status, headers) do
        {:ok, conn, websocket} ->
          state = %{
            state
            | conn: conn,
              websocket: websocket,
              status: :awaiting_welcome,
              awaiting_welcome?: true,
              upgrade_status: nil,
              upgrade_headers: nil,
              upgrade_done: false
          }

          case send_frame(Frame.new(:hello, state.local_handshake_payload), state) do
            {:ok, new_state} -> {:ok, new_state}
            {:error, reason, new_state} -> {:error, reason, new_state}
          end

        {:error, conn, reason} ->
          {:error, reason, %{state | conn: conn}}
      end
    rescue
      exception ->
        Logger.error("Mint.WebSocket.new failed: #{inspect(exception)}")
        {:error, exception, state}
    end
  end

  defp complete_upgrade(state, _ref), do: {:ok, state}

  defp maybe_finalize_upgrade({:noreply, state}) do
    case complete_upgrade_if_ready(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason, new_state} -> {:stop, reason, new_state}
    end
  end

  defp maybe_finalize_upgrade(other), do: other

  defp complete_upgrade_if_ready(%{status: :awaiting_upgrade, upgrade_done: true} = state) do
    Logger.debug("completing upgrade with headers=#{inspect(state.upgrade_headers)} status=#{inspect(state.upgrade_status)}")
    case state.upgrade_headers do
      headers when is_list(headers) -> complete_upgrade(state, state.request_ref)
      _ -> {:ok, state}
    end
  end

  defp complete_upgrade_if_ready(state), do: {:ok, state}

  defp normalize_response({:stop, reason, state}), do: {:stop, reason, state}
  defp normalize_response(other), do: other

  defp generate_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end
end
