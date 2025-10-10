defmodule RpcEx.Integration.Client2ConnectTest do
  use ExUnit.Case

  alias RpcEx.Client2
  alias RpcEx.Server

  @moduletag :integration

  setup do
    tracker = start_supervised!({RpcEx.Test.Integration.Tracker, []})
    port = Enum.random(40_000..49_000)

    server =
      start_supervised!({Server,
        router: RpcEx.Test.Integration.ServerRouter,
        port: port
      })

    %{port: port, server: server, tracker: tracker}
  end

  test "client2 connects to server", %{port: port} do
    client = start_supervised!({Client2, host: "localhost", port: port, path: "/"})

    state = Client2.state(client)

    assert %Mint.WebSocket{} = state.websocket
    assert state.host == "localhost"
    assert state.port == port
  end
end
