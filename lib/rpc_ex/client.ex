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

  alias Horde.Registry
  alias Mint.{HTTP, WebSocket}
  alias RpcEx.Client.Connection
  alias RpcEx.Peer
  alias RpcEx.Protocol.{Frame, Handshake}

  @subprotocol "rpc_ex.etf.v1"

  @type option ::
          {:name, GenServer.name()}
          | {:url, String.t()}
          | {:scheme, :http | :https}
          | {:host, String.t()}
          | {:port, :inet.port_number()}
          | {:path, String.t()}
          | {:router, module()}
          | {:timeout, non_neg_integer()}
          | {:handshake, keyword()}
          | {:context, map()}
          | {:reconnect, boolean() | keyword()}
          | {:telemetry_prefix, [atom()]}
          | {:transport_opts, keyword()}
          | {:websocket_opts, keyword()}
          | {:headers, [{binary(), binary()}]}
          | {:horde, keyword() | map()}

  @type call_option ::
          {:timeout, non_neg_integer()}
          | {:args, term()}
          | {:meta, map()}

  @typedoc "Opaque reference for async call tracking."
  @type call_ref :: binary()

  defmodule State do
    @moduledoc false
    defstruct conn: nil,
              websocket: nil,
              request_ref: nil,
              status: nil,
              connection_status: :connecting,
              router: nil,
              connection: nil,
              pending: %{},
              pending_peer_calls: %{},
              timeout: 5_000,
              handshake: nil,
              handshake_payload: nil,
              scheme: :http,
              host: "localhost",
              port: 80,
              path: "/",
              transport_opts: [],
              websocket_opts: [],
              hello_sent?: false,
              reconnect_config: nil,
              reconnect_attempt: 0,
              reconnect_timer: nil,
              headers: [],
              horde_registry: nil,
              horde_key: nil,
              horde_meta: %{}
  end

  ## Public API

  @doc """
  Starts the client.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
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
    router = Keyword.get(opts, :router)
    handshake_opts = Keyword.get(opts, :handshake, [])
    timeout = Keyword.get(opts, :timeout, 5_000)
    context = Keyword.get(opts, :context, %{})
    transport_opts = Keyword.get(opts, :transport_opts, [])
    websocket_opts = Keyword.get(opts, :websocket_opts, compress: false)
    headers = Keyword.get(opts, :headers, [])
    reconnect_config = parse_reconnect_config(Keyword.get(opts, :reconnect, true))

    {scheme, host, port, path} = connection_target(opts)

    local_handshake = Handshake.build(handshake_opts)

    handshake_payload =
      local_handshake
      |> Map.from_struct()
      |> Map.put(:meta, Map.get(local_handshake, :meta, %{}))

    state = %State{
      router: router,
      connection: Connection.new(router: router, session: %{}, context: context),
      timeout: timeout,
      handshake: local_handshake,
      handshake_payload: handshake_payload,
      scheme: scheme,
      host: host,
      port: port,
      path: path,
      transport_opts: transport_opts,
      websocket_opts: websocket_opts,
      headers: headers,
      reconnect_config: reconnect_config,
      connection_status: :connecting
    }

    state = maybe_register_with_horde(state, opts)

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    http_scheme = transport_scheme(state.scheme)
    ws_scheme = ws_scheme(state.scheme)

    case HTTP.connect(http_scheme, state.host, state.port, state.transport_opts) do
      {:ok, conn} ->
        headers = upgrade_headers(state)

        case WebSocket.upgrade(
               ws_scheme,
               conn,
               state.path,
               headers,
               Keyword.put_new(state.websocket_opts, :subprotocols, [@subprotocol])
             ) do
          {:ok, conn, ref} ->
            {:noreply, %{state | conn: conn, request_ref: ref}}

          {:error, conn, error} ->
            Logger.error("WebSocket upgrade failed: #{inspect(error)}")
            handle_disconnect({:upgrade_failed, error}, %{state | conn: conn})
        end

      {:error, error} ->
        Logger.error("HTTP connection failed: #{inspect(error)}")
        handle_disconnect({:connection_failed, error}, state)
    end
  end

  @impl GenServer
  def handle_continue(:reconnect, state) do
    # Same as :connect but called during reconnection
    handle_continue(:connect, state)
  end

  @impl GenServer
  def handle_call({:call, route, opts}, from, %{connection_status: :ready} = state) do
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

    case send_frame(Frame.new(:call, payload), state) do
      {:ok, state} ->
        timer =
          cond do
            timeout == :infinity -> nil
            timeout -> Process.send_after(self(), {:pending_timeout, msg_id}, timeout)
            true -> nil
          end

        pending = Map.put(state.pending, msg_id, %{from: from, timer: timer, type: :call})
        {:noreply, %{state | pending: pending}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, _route, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:cast, route, opts}, _from, %{connection_status: :ready} = state) do
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

  def handle_call({:cast, _route, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:discover, opts}, from, %{connection_status: :ready} = state) do
    scope = Keyword.get(opts, :scope, :all)
    msg_id = generate_id()
    payload = %{msg_id: msg_id, scope: scope, meta: %{}}

    case send_frame(Frame.new(:discover, payload), state) do
      {:ok, state} ->
        pending = Map.put(state.pending, msg_id, %{from: from, timer: nil, type: :discover})
        {:noreply, %{state | pending: pending}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discover, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl GenServer
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect...")
    {:noreply, state, {:continue, :reconnect}}
  end

  def handle_info({:pending_timeout, msg_id}, state) do
    case Map.pop(state.pending, msg_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl GenServer
  def handle_info(message, %{conn: %{socket: socket}} = state)
      when is_tuple(message) and
             elem(message, 0) in [:tcp, :ssl, :tcp_closed, :ssl_closed, :tcp_error, :ssl_error] and
             elem(message, 1) == socket do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        process_responses(responses, state)

      {:error, conn, error, _responses} ->
        Logger.error("WebSocket stream error: #{inspect(error)}")
        handle_disconnect({:stream_error, error}, %{state | conn: conn})

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:peer_call, ref, frame, from_pid}, state) do
    %Frame{payload: %{msg_id: msg_id}} = frame
    pending = Map.put(state.pending_peer_calls, msg_id, {ref, from_pid})

    case send_frame(frame, %{state | pending_peer_calls: pending}) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason, new_state} -> handle_disconnect({:peer_call_failed, reason}, new_state)
    end
  end

  def handle_info({:peer_cast, frame}, state) do
    case send_frame(frame, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason, new_state} -> handle_disconnect({:peer_cast_failed, reason}, new_state)
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
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

  ## Internal helpers - Response Processing

  defp process_responses(responses, state) do
    Enum.reduce(responses, {:noreply, state}, fn response, {:noreply, state} ->
      process_response(response, state)
    end)
  end

  defp process_response({:status, ref, status}, %{request_ref: ref} = state) do
    {:noreply, %{state | status: status}}
  end

  defp process_response({:headers, ref, headers}, %{request_ref: ref} = state) do
    case WebSocket.new(state.conn, ref, state.status || 101, headers) do
      {:ok, conn, websocket} ->
        state = %{
          state
          | conn: conn,
            websocket: websocket,
            status: nil,
            headers: nil,
            connection_status: :awaiting_welcome
        }

        # Send hello frame immediately after upgrade completes
        case send_frame(Frame.new(:hello, state.handshake_payload), state) do
          {:ok, state} ->
            {:noreply, %{state | hello_sent?: true}}

          {:error, reason, state} ->
            Logger.error("Failed to send hello: #{inspect(reason)}")
            handle_disconnect({:hello_failed, reason}, state)
        end

      {:error, conn, error} ->
        Logger.error("WebSocket.new failed: #{inspect(error)}")
        handle_disconnect({:websocket_new_failed, error}, %{state | conn: conn})
    end
  end

  defp process_response({:data, ref, _data}, %{request_ref: ref, websocket: nil} = state) do
    # Skip data if websocket not ready yet
    {:noreply, state}
  end

  defp process_response({:data, ref, data}, %{request_ref: ref, websocket: websocket} = state) do
    case WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        handle_frames(frames, state)

      {:error, websocket, error} ->
        Logger.error("WebSocket decode error: #{inspect(error)}")
        {:noreply, %{state | websocket: websocket}}
    end
  end

  defp process_response({:done, ref}, %{request_ref: ref} = state) do
    {:noreply, state}
  end

  defp process_response(_response, state) do
    {:noreply, state}
  end

  ## Frame Handling

  defp handle_frames(frames, state) do
    Enum.reduce(frames, {:noreply, state}, fn frame, {:noreply, state} ->
      handle_frame(frame, state)
    end)
  end

  defp handle_frame({:close, code, reason}, state) do
    handle_disconnect({:remote_close, {code, reason}}, state)
  end

  defp handle_frame({:ping, data}, state) do
    case send_ws_frame({:pong, data}, state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> handle_disconnect({:pong_failed, reason}, state)
    end
  end

  defp handle_frame({:pong, _data}, state) do
    {:noreply, state}
  end

  defp handle_frame({:binary, data}, state) do
    case Frame.decode(data) do
      {:ok, frame} ->
        handle_rpc_frame(frame, state)

      {:error, reason} ->
        Logger.error("Failed to decode frame: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp handle_frame({:text, _data}, state) do
    Logger.warning("Received unexpected text frame")
    {:noreply, state}
  end

  defp handle_frame(_frame, state) do
    {:noreply, state}
  end

  ## RPC Frame Handling

  defp handle_rpc_frame(%Frame{type: :welcome, payload: payload}, state) do
    case Handshake.negotiate(state.handshake, payload) do
      {:ok, session} ->
        # Create peer handle for bidirectional RPC
        peer = Peer.new(handler_pid: self(), timeout: 5_000)

        # Inject peer into context so handlers can call back to server
        context =
          state.connection.context
          |> Map.put(:peer, peer)

        connection =
          state.connection
          |> Connection.put_router(state.router)
          |> Map.replace!(:session, session)
          |> Map.replace!(:context, context)

        # Successful connection - reset reconnect attempt counter
        Logger.info("Client connected and ready")

        state =
          state
          |> Map.put(:connection_status, :ready)
          |> Map.put(:connection, connection)
          |> Map.put(:reconnect_attempt, 0)
          |> put_horde_meta(session_horde_meta(session))

        {:noreply, update_horde_status(state, :ready)}

      {:error, reason} ->
        Logger.error("Handshake negotiation failed: #{inspect(reason)}")
        handle_disconnect({:handshake_failed, reason}, state)
    end
  end

  defp handle_rpc_frame(%Frame{type: :reply, payload: payload}, state) do
    # Check if this is a peer call response first
    case handle_peer_response(:reply, payload, state) do
      {:handled, new_state} ->
        {:noreply, new_state}

      :not_found ->
        # Regular client-initiated call response
        {:noreply, handle_reply(payload, state)}
    end
  end

  defp handle_rpc_frame(%Frame{type: :error, payload: payload}, state) do
    # Check if this is a peer call response first
    case handle_peer_response(:error, payload, state) do
      {:handled, new_state} ->
        {:noreply, new_state}

      :not_found ->
        # Regular client-initiated call error response
        {:noreply, handle_error_reply(payload, state)}
    end
  end

  defp handle_rpc_frame(%Frame{type: :discover_reply, payload: payload}, state) do
    {:noreply, handle_discover_reply(payload, state)}
  end

  defp handle_rpc_frame(%Frame{type: type} = frame, state)
       when type in [:call, :cast, :discover] do
    case Connection.handle_frame(frame, state.connection) do
      {:reply, reply_frame, new_conn} ->
        case send_frame(reply_frame, %{state | connection: new_conn}) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason, new_state} -> handle_disconnect({:send_failed, reason}, new_state)
        end

      {:push, push_frame, new_conn} ->
        case send_frame(push_frame, %{state | connection: new_conn}) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason, new_state} -> handle_disconnect({:send_failed, reason}, new_state)
        end

      {:noreply, new_conn} ->
        {:noreply, %{state | connection: new_conn}}
    end
  end

  defp handle_rpc_frame(%Frame{type: :notify, payload: payload}, state) do
    Logger.debug("Received notify: #{inspect(payload)}")
    {:noreply, state}
  end

  defp handle_rpc_frame(%Frame{type: type}, state) do
    Logger.warning("Received unexpected frame type: #{inspect(type)}")
    {:noreply, state}
  end

  ## Peer Call Response Handling

  defp handle_peer_response(:reply, %{msg_id: msg_id} = payload, state) do
    %{result: result} = payload
    meta = Map.get(payload, :meta, %{})

    case Map.pop(state.pending_peer_calls, msg_id) do
      {nil, _pending} ->
        :not_found

      {{ref, from_pid}, pending} ->
        send(from_pid, {:peer_reply, ref, {:ok, result, meta}})
        {:handled, %{state | pending_peer_calls: pending}}
    end
  end

  defp handle_peer_response(:error, %{msg_id: msg_id} = payload, state) do
    %{reason: reason} = payload
    detail = Map.get(payload, :detail)

    case Map.pop(state.pending_peer_calls, msg_id) do
      {nil, _pending} ->
        :not_found

      {{ref, from_pid}, pending} ->
        send(from_pid, {:peer_reply, ref, {:error, {reason, detail}}})
        {:handled, %{state | pending_peer_calls: pending}}
    end
  end

  ## Reply Handling

  defp handle_reply(%{msg_id: msg_id} = payload, state) do
    case Map.pop(state.pending, msg_id) do
      {nil, _pending} ->
        state

      {%{from: from, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        result = Map.get(payload, :result)
        meta = Map.get(payload, :meta, %{})
        GenServer.reply(from, {:ok, result, meta})
        %{state | pending: pending}
    end
  end

  defp handle_error_reply(%{msg_id: msg_id} = payload, state) do
    case Map.pop(state.pending, msg_id) do
      {nil, _pending} ->
        state

      {%{from: from, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        reason = Map.get(payload, :reason, :unknown)
        detail = Map.get(payload, :detail)
        GenServer.reply(from, {:error, {reason, detail}})
        %{state | pending: pending}
    end
  end

  defp handle_discover_reply(%{msg_id: msg_id} = payload, state) do
    case Map.pop(state.pending, msg_id) do
      {nil, _pending} ->
        state

      {%{from: from}, pending} ->
        entries = Map.get(payload, :entries, [])
        meta = Map.get(payload, :meta, %{})
        GenServer.reply(from, {:ok, entries, meta})
        %{state | pending: pending}
    end
  end

  ## Frame Sending

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
      {:error, websocket, reason} when is_struct(websocket, WebSocket) ->
        {:error, reason, %{state | websocket: websocket}}

      {:error, conn, reason} when is_struct(conn, HTTP) ->
        {:error, reason, %{state | conn: conn}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp upgrade_headers(state) do
    base = [
      {"host", host_header(state.host, state.port, state.scheme)},
      {"sec-websocket-protocol", @subprotocol}
    ]

    merge_headers(base, state.headers)
  end

  defp merge_headers(base, headers) when is_list(headers) do
    Enum.reduce(headers, base, fn
      {key, value}, acc when is_binary(key) and is_binary(value) ->
        acc ++ [{key, value}]

      _, acc ->
        acc
    end)
  end

  defp merge_headers(base, _headers), do: base

  ## Connection Target Parsing

  defp connection_target(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, url} ->
        uri = URI.parse(url)
        scheme = normalize_scheme(uri.scheme)
        host = uri.host || raise ArgumentError, "url must include host"
        port = uri.port || default_port(scheme)
        path = normalize_path(uri.path, uri.query)
        {scheme, host, port, path}

      :error ->
        scheme = normalize_scheme(Keyword.get(opts, :scheme, :http))
        host = Keyword.get(opts, :host, "localhost")
        port = Keyword.get(opts, :port, default_port(scheme))
        path = normalize_path(Keyword.get(opts, :path, "/"), nil)
        {scheme, host, port, path}
    end
  end

  defp normalize_scheme(:http), do: :http
  defp normalize_scheme(:https), do: :https
  defp normalize_scheme("ws"), do: :http
  defp normalize_scheme("wss"), do: :https
  defp normalize_scheme("http"), do: :http
  defp normalize_scheme("https"), do: :https
  defp normalize_scheme(nil), do: :http

  defp normalize_scheme(other) do
    raise ArgumentError, "unsupported scheme #{inspect(other)}"
  end

  defp transport_scheme(:http), do: :http
  defp transport_scheme(:https), do: :https

  defp ws_scheme(:https), do: :wss
  defp ws_scheme(:http), do: :ws

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

  defp generate_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end

  ## Reconnection Logic

  defp parse_reconnect_config(false), do: nil
  defp parse_reconnect_config(nil), do: nil

  defp parse_reconnect_config(true) do
    %{
      enabled: true,
      strategy: :exponential,
      initial_delay: 100,
      max_delay: 30_000,
      max_attempts: :infinity,
      jitter: true
    }
  end

  defp parse_reconnect_config(opts) when is_list(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, true),
      strategy: Keyword.get(opts, :strategy, :exponential),
      initial_delay: Keyword.get(opts, :initial_delay, 100),
      max_delay: Keyword.get(opts, :max_delay, 30_000),
      max_attempts: Keyword.get(opts, :max_attempts, :infinity),
      jitter: Keyword.get(opts, :jitter, true)
    }
  end

  defp handle_disconnect(reason, state) do
    Logger.warning("Client disconnected: #{inspect(reason)}")

    # Fail all pending calls
    state = fail_pending_calls(state, {:error, :disconnected})

    # Clean up connection state
    state =
      state
      |> Map.put(:conn, nil)
      |> Map.put(:websocket, nil)
      |> Map.put(:request_ref, nil)
      |> Map.put(:connection_status, :disconnected)
      |> update_horde_status(:disconnected, %{last_error: inspect(reason)})

    case should_reconnect?(state) do
      true ->
        schedule_reconnect(state)

      false ->
        {:stop, reason, state}
    end
  end

  defp should_reconnect?(%{reconnect_config: nil}), do: false
  defp should_reconnect?(%{reconnect_config: %{enabled: false}}), do: false

  defp should_reconnect?(%{reconnect_config: %{max_attempts: :infinity}}), do: true

  defp should_reconnect?(%{reconnect_config: %{max_attempts: max}, reconnect_attempt: attempt}) do
    attempt < max
  end

  defp schedule_reconnect(state) do
    delay = calculate_backoff(state)
    Logger.info("Scheduling reconnect attempt #{state.reconnect_attempt + 1} in #{delay}ms")

    timer = Process.send_after(self(), :reconnect, delay)
    next_attempt = state.reconnect_attempt + 1

    state =
      state
      |> Map.put(:reconnect_timer, timer)
      |> Map.put(:reconnect_attempt, next_attempt)
      |> update_horde_status(:connecting, %{reconnect_attempt: next_attempt, reconnect_in: delay})

    {:noreply, state}
  end

  defp calculate_backoff(%{reconnect_config: config, reconnect_attempt: attempt}) do
    %{initial_delay: initial, max_delay: max, strategy: :exponential, jitter: add_jitter?} =
      config

    # Exponential backoff: initial * 2^attempt, capped at max
    delay = min(initial * :math.pow(2, attempt), max) |> trunc()

    # Add jitter (±25%) to prevent thundering herd
    if add_jitter? do
      jitter = trunc(delay * 0.25)
      delay + :rand.uniform(jitter * 2) - jitter
    else
      delay
    end
  end

  defp fail_pending_calls(%{pending: pending} = state, error) do
    Enum.each(pending, fn {_msg_id, %{from: from, timer: timer}} ->
      if timer, do: Process.cancel_timer(timer)
      GenServer.reply(from, error)
    end)

    %{state | pending: %{}}
  end

  ## Horde integration helpers

  defp maybe_register_with_horde(state, opts) do
    opts
    |> Keyword.get(:horde)
    |> normalize_horde_opts()
    |> register_with_horde(state)
  end

  defp register_with_horde(nil, state), do: state

  defp register_with_horde(%{registry: registry, key: key} = opts, state)
       when is_atom(registry) do
    base_meta =
      opts
      |> Map.get(:meta, %{})
      |> Map.new()
      |> Map.merge(%{node: node()})
      |> maybe_put(:pool, Map.get(opts, :pool))
      |> maybe_put(:index, Map.get(opts, :index))

    case safe_register(registry, key, Map.put(base_meta, :status, :connecting)) do
      {:ok, _pid} ->
        state = %{state | horde_registry: registry, horde_key: key, horde_meta: base_meta}
        update_horde_status(state, :connecting)

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "Horde registry already has an entry for #{inspect(key)} (#{inspect(pid)})"
        )

        state = %{state | horde_registry: registry, horde_key: key, horde_meta: base_meta}
        update_horde_status(state, :connecting)

      {:error, reason} ->
        Logger.warning("Failed to register RpcEx client with Horde: #{inspect(reason)}")
        state
    end
  end

  defp register_with_horde(_invalid, state) do
    Logger.warning("Ignoring invalid Horde options for RpcEx client")
    state
  end

  defp normalize_horde_opts(nil), do: nil
  defp normalize_horde_opts(%{} = opts), do: opts
  defp normalize_horde_opts(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp normalize_horde_opts(_), do: nil

  defp safe_register(registry, key, meta) do
    Registry.register(registry, key, meta)
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
      |> Map.merge(%{node: node(), timeout: state.timeout})
      |> Map.merge(extra)
      |> Map.put(:status, status)
      |> compact_meta()

    case Registry.update_value(state.horde_registry, state.horde_key, fn _ -> meta end) do
      {:error, _} -> state
      _ -> state
    end
  rescue
    _ -> state
  end

  defp put_horde_meta(%{horde_registry: nil} = state, _meta), do: state

  defp put_horde_meta(state, meta) when is_map(meta) do
    %{state | horde_meta: Map.merge(state.horde_meta, meta)}
  end

  defp put_horde_meta(state, _meta), do: state

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
end
