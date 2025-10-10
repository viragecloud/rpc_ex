defmodule RpcEx.Integration.ClientConnectTest do
  use ExUnit.Case

  alias RpcEx.Client
  alias RpcEx.Server

  @moduletag :integration

  setup do
    tracker = start_supervised!({RpcEx.Test.Integration.Tracker, []})
    port = Enum.random(40_000..49_000)

    server =
      start_supervised!({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

    %{port: port, server: server, tracker: tracker}
  end

  test "client connects to server", %{port: port} do
    client = start_supervised!({Client, host: "localhost", port: port, path: "/"})

    # Wait for connection to be ready
    wait_for_ready(client)

    state = :sys.get_state(client)

    assert %Mint.WebSocket{} = state.websocket
    assert state.host == "localhost"
    assert state.port == port
  end

  defp wait_for_ready(client, attempts \\ 50)

  defp wait_for_ready(_client, 0), do: :ok

  defp wait_for_ready(client, attempts) do
    case :sys.get_state(client) do
      %{connection_status: :ready} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_for_ready(client, attempts - 1)
    end
  end
end
