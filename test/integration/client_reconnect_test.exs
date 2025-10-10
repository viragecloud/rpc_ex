defmodule RpcEx.Integration.ClientReconnectTest do
  use ExUnit.Case

  alias RpcEx.{Client, Server}

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    tracker = start_supervised!({RpcEx.Test.Integration.Tracker, []})
    port = Enum.random(40_000..49_000)

    %{port: port, tracker: tracker}
  end

  test "client reconnects after server disconnect", %{port: port} do
    # Start server
    {:ok, _server_pid} =
      start_supervised({Server,
        router: RpcEx.Test.Integration.ServerRouter,
        port: port
      })

    # Start client with fast reconnect for testing
    {:ok, client_pid} =
      start_supervised({Client,
        url: "ws://localhost:#{port}/",
        router: RpcEx.Test.Integration.ClientRouter,
        reconnect: [
          enabled: true,
          initial_delay: 100,
          max_delay: 1_000,
          max_attempts: 5,
          jitter: false
        ]
      })

    # Wait for initial connection
    wait_for_ready(client_pid)

    # Verify client can make calls
    assert {:ok, %{pong: :ping}, _meta} = Client.call(client_pid, :ping, args: %{ping: :ping})

    # Stop the server to simulate disconnect
    stop_supervised(Server)
    Process.sleep(200)

    # Verify client is disconnected
    state = :sys.get_state(client_pid)
    assert state.connection_status == :disconnected
    assert state.reconnect_attempt >= 1

    # Verify pending calls fail with :disconnected
    assert {:error, :not_connected} = Client.call(client_pid, :ping, args: %{ping: :ping})

    # Restart server
    {:ok, _new_server_pid} =
      start_supervised({Server,
        router: RpcEx.Test.Integration.ServerRouter,
        port: port
      })

    # Wait for reconnection (with retries)
    wait_for_ready(client_pid, 100)

    # Verify client reconnected and can make calls again
    assert {:ok, %{pong: :ping}, _meta} = Client.call(client_pid, :ping, args: %{ping: :ping})

    # Verify reconnect counter was reset
    state = :sys.get_state(client_pid)
    assert state.reconnect_attempt == 0
  end

  test "client stops after max reconnect attempts", %{port: port} do
    # Start client with reconnect enabled but max 3 attempts
    # Don't start a server - connection will always fail
    {:ok, client_pid} =
      start_supervised({Client,
        url: "ws://localhost:#{port}/",
        router: RpcEx.Test.Integration.ClientRouter,
        reconnect: [
          enabled: true,
          initial_delay: 50,
          max_delay: 200,
          max_attempts: 3,
          jitter: false
        ]
      })

    # Monitor the client
    ref = Process.monitor(client_pid)

    # Wait for client to give up and terminate
    assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 5_000
  end

  test "client with reconnect disabled stops on disconnect", %{port: port} do
    # Start server
    {:ok, _server_pid} =
      start_supervised({Server,
        router: RpcEx.Test.Integration.ServerRouter,
        port: port
      })

    # Start client with reconnect disabled
    {:ok, client_pid} =
      start_supervised({Client,
        url: "ws://localhost:#{port}/",
        router: RpcEx.Test.Integration.ClientRouter,
        reconnect: false
      })

    # Wait for initial connection
    wait_for_ready(client_pid)

    # Monitor the client
    ref = Process.monitor(client_pid)

    # Stop the server
    stop_supervised(Server)

    # Client should terminate (not reconnect)
    assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 2_000
  end

  defp wait_for_ready(client, attempts \\ 50)

  defp wait_for_ready(_client, 0) do
    flunk("Client did not become ready")
  end

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
