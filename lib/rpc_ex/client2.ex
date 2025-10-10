defmodule RpcEx.Client2 do
  @moduledoc false

  use GenServer

  alias Mint.HTTP
  alias Mint.WebSocket

  @subprotocol "rpc_ex.etf.v1"

  @type state :: %{
          conn: Mint.HTTP.t(),
          websocket: Mint.WebSocket.t(),
          request_ref: Mint.Types.request_ref(),
          host: String.t(),
          port: :inet.port_number(),
          path: String.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  def state(pid) do
    :sys.get_state(pid)
  end

  @impl GenServer
  def init(opts) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 9_000)
    path = Keyword.get(opts, :path, "/")
    headers = [
      {"host", host_header(host, port)},
      {"sec-websocket-protocol", @subprotocol}
    ]

    {:ok, conn} = HTTP.connect(:http, host, port)
    {:ok, conn, ref} = WebSocket.upgrade(:ws, conn, path, headers)

    http_reply_message =
      receive do
        message -> message
      end

    {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers}, {:done, ^ref}]} =
      WebSocket.stream(conn, http_reply_message)

    {:ok, conn, websocket} = WebSocket.new(conn, ref, status, resp_headers)

    state = %{
      conn: conn,
      websocket: websocket,
      request_ref: ref,
      host: host,
      port: port,
      path: path
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(message, %{conn: conn} = state) do
    case WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        {:stop, reason, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref} = state) do
    case WebSocket.stream(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.each(frames, &handle_frame/1)
        handle_responses(rest, %{state | websocket: websocket})

      {:error, websocket, reason} ->
        {:stop, reason, %{state | websocket: websocket}}
    end
  end

  defp handle_responses([_other | rest], state) do
    handle_responses(rest, state)
  end

  defp handle_frame(_frame), do: :ok

  defp host_header(host, 80), do: host
  defp host_header(host, port), do: "#{host}:#{port}"
end
