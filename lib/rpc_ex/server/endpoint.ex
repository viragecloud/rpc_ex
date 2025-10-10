defmodule RpcEx.Server.Endpoint do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @subprotocol "rpc_ex.etf.v1"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    handler_opts = %{
      router: Keyword.fetch!(opts, :router),
      handshake_opts: Keyword.get(opts, :handshake, []),
      context: Keyword.get(opts, :context, %{})
    }

    websocket_opts =
      opts
      |> Keyword.get(:websocket, [])
      |> Keyword.put_new(:subprotocols, [@subprotocol])

    conn
    |> put_resp_header("sec-websocket-protocol", @subprotocol)
    |> upgrade_adapter(:websocket, {RpcEx.Server.WebSocketHandler, handler_opts, websocket_opts})
  end
end
