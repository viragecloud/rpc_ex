defmodule RpcEx.Integration.ClientFlowTest do
  use ExUnit.Case

  alias RpcEx.Client
  alias RpcEx.Server

  @moduletag :integration

  setup do
    tracker = start_supervised!({RpcEx.Test.Integration.Tracker, []})
    port = Enum.random(40_000..49_000)

    server =
      start_supervised!({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

    client =
      start_supervised!(
        {Client, url: "ws://localhost:#{port}/", router: RpcEx.Test.Integration.ClientRouter}
      )

    wait_for_ready(client)

    %{client: client, server: server, tracker: tracker}
  end

  test "client can call server", %{client: client} do
    assert {:ok, %{pong: :ping}, _meta} = Client.call(client, :ping, args: %{ping: :ping})
  end

  test "client router receives server call", %{client: client} do
    assert {:ok, _result, _meta} =
             Client.call(client, :server_to_client, args: %{hello: :world})

    # The middleware adds trace: :client to the args
    assert {:client_call, %{trace: :client, hello: :world}} in RpcEx.Test.Integration.Tracker.drain()
  end

  test "client discover returns routes", %{client: client} do
    {:ok, entries, _meta} = Client.discover(client)
    assert Enum.any?(entries, &(&1.route == :ping))
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
