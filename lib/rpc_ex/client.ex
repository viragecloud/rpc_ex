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
          | {:scheme, :http | :https}
          | {:host, String.t()}
          | {:port, :inet.port_number()}
          | {:path, String.t()}
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

  defmodule State do
    @moduledoc false
    defstruct conn: nil,
              websocket: nil,
              request_ref: nil,
              status: nil,
              headers: nil,
              connection_status: :connecting,
              router: nil,
              connection: nil,
              pending: %{},
              timeout: 5_000,
              handshake: nil,
              handshake_payload: nil,
              scheme: :http,
              host: "localhost",
              port: 80,
              path: "/",
              transport_opts: [],
              websocket_opts: [],
              hello_sent?: false
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
      connection_status: :connecting
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    http_scheme = transport_scheme(state.scheme)
    ws_scheme = ws_scheme(state.scheme)

    case HTTP.connect(http_scheme, state.host, state.port, state.transport_opts) do
      {:ok, conn} ->
        case WebSocket.upgrade(
               ws_scheme,
               conn,
               state.path,
               [
                 {"host", host_header(state.host, state.port, state.scheme)},
                 {"sec-websocket-protocol", @subprotocol}
               ],
               Keyword.put_new(state.websocket_opts, :subprotocols, [@subprotocol])
             ) do
          {:ok, conn, ref} ->
            {:noreply, %{state | conn: conn, request_ref: ref}}

          {:error, conn, error} ->
            Logger.error("WebSocket upgrade failed: #{inspect(error)}")
            {:stop, error, %{state | conn: conn}}
        end

      {:error, error} ->
        Logger.error("HTTP connection failed: #{inspect(error)}")
        {:stop, error, state}
    end
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
        {:stop, {:error, error}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
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
            {:stop, reason, state}
        end

      {:error, conn, error} ->
        Logger.error("WebSocket.new failed: #{inspect(error)}")
        {:stop, error, %{state | conn: conn}}
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

  defp handle_frame({:close, _code, _reason}, state) do
    {:stop, :normal, state}
  end

  defp handle_frame({:ping, data}, state) do
    case send_ws_frame({:pong, data}, state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, state}
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
        connection =
          state.connection
          |> Connection.put_router(state.router)
          |> Map.replace!(:session, session)

        {:noreply,
         %{
           state
           | connection_status: :ready,
             connection: connection
         }}

      {:error, reason} ->
        Logger.error("Handshake negotiation failed: #{inspect(reason)}")
        {:stop, {:handshake_failed, reason}, state}
    end
  end

  defp handle_rpc_frame(%Frame{type: :reply, payload: payload}, state) do
    {:noreply, handle_reply(payload, state)}
  end

  defp handle_rpc_frame(%Frame{type: :error, payload: payload}, state) do
    {:noreply, handle_error_reply(payload, state)}
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
          {:error, reason, new_state} -> {:stop, reason, new_state}
        end

      {:push, push_frame, new_conn} ->
        case send_frame(push_frame, %{state | connection: new_conn}) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason, new_state} -> {:stop, reason, new_state}
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
end
