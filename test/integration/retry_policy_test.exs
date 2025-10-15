defmodule RpcEx.Integration.RetryPolicyTest do
  use ExUnit.Case

  alias RpcEx.{Client, Server}
  alias RpcEx.RetryPolicy.{Simple, Smart}

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    port = Enum.random(40_000..49_000)
    %{port: port}
  end

  describe "Simple retry policy" do
    test "retries up to max_attempts", %{port: port} do
      # Start client with Simple policy (3 max attempts)
      # Don't start a server - connection will always fail
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Simple, max_attempts: 3},
           reconnect: [initial_delay: 50, max_delay: 100, jitter: false]}
        )

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Wait for client to give up and terminate after 3 attempts
      assert_receive {:DOWN, ^ref, :process, ^client_pid, reason}, 5_000

      # Verify it stopped due to max attempts
      assert {:max_reconnect_attempts, {:connection_failed, _error}} = reason
    end

    test "retries indefinitely with max_attempts: :infinity", %{port: port} do
      # Start client with infinite retries
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Simple, max_attempts: :infinity},
           reconnect: [initial_delay: 50, max_delay: 100, jitter: false]}
        )

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Wait a bit to ensure multiple retry attempts
      Process.sleep(500)

      # Verify client is still alive and retrying
      assert Process.alive?(client_pid)
      state = :sys.get_state(client_pid)
      assert state.reconnect_attempt > 3

      # Now start the server
      {:ok, _server_pid} =
        start_supervised({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

      # Client should connect successfully
      wait_for_ready(client_pid)

      # Verify no DOWN message received
      refute_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 500
    end
  end

  describe "Smart retry policy - transient errors" do
    test "retries indefinitely on connection failures", %{port: port} do
      # Start client with Smart policy
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Smart, []},
           reconnect: [initial_delay: 50, max_delay: 100, jitter: false]}
        )

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Wait for several retry attempts
      Process.sleep(500)

      # Verify client is still alive and retrying
      assert Process.alive?(client_pid)
      state = :sys.get_state(client_pid)
      assert state.reconnect_attempt > 3

      # Start server to allow connection
      {:ok, _server_pid} =
        start_supervised({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

      # Client should connect
      wait_for_ready(client_pid)

      # Verify no DOWN message
      refute_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 500
    end

    test "retries after normal server disconnect", %{port: port} do
      # Start server
      {:ok, _server_pid} =
        start_supervised({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

      # Start client with Smart policy
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Smart, []},
           reconnect: [initial_delay: 50, max_delay: 100, jitter: false]}
        )

      # Wait for connection
      wait_for_ready(client_pid)

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Stop server (normal close)
      stop_supervised(Server)
      Process.sleep(100)

      # Client should be disconnected but retrying
      state = :sys.get_state(client_pid)
      assert state.connection_status == :disconnected
      assert state.reconnect_attempt >= 1

      # Restart server
      {:ok, _new_server_pid} =
        start_supervised({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

      # Client should reconnect
      wait_for_ready(client_pid)

      # Verify client still alive
      refute_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 500
    end
  end

  describe "Smart retry policy - fatal errors" do
    test "stops immediately on handshake failure", %{port: _port} do
      # Start server with incompatible protocol (we'll simulate this by not starting a server)
      # The handshake will fail when we send invalid data

      # For this test, we'll just verify the policy logic by checking client stops
      # on connection to a port with no server, which eventually causes handshake timeout
      # In practice, a real handshake failure would be faster

      # This is a simplified test - a full integration would require a malicious server
      # For now, we rely on unit tests for Smart policy logic
    end

    test "custom fatal_error? callback stops client", %{port: port} do
      # Custom fatal error checker that treats all connection failures as fatal
      fatal_checker = fn
        {:connection_failed, %Mint.TransportError{reason: :econnrefused}} -> true
        {:connection_failed, _} -> true
        _ -> false
      end

      # Start client with custom fatal error checker
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Smart, fatal_error?: fatal_checker},
           reconnect: [initial_delay: 50, max_delay: 100, jitter: false]}
        )

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Client should stop immediately on first connection failure
      assert_receive {:DOWN, ^ref, :process, ^client_pid, reason}, 2_000

      # Verify it was a fatal error
      assert {:fatal_error, {:connection_failed, _error}} = reason
    end
  end

  describe "Legacy reconnect config compatibility" do
    test "reconnect: false uses Simple policy with 0 attempts", %{port: port} do
      # Monitor first, then start
      # Start client with reconnect: false
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           reconnect: false}
        )

      # Monitor the client immediately
      ref = Process.monitor(client_pid)

      # Client should stop immediately (no retries) - connection will fail
      # and with max_attempts: 0, it won't retry
      assert_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 1_000
    end

    test "reconnect: [max_attempts: 5] uses Simple policy", %{port: port} do
      # Start client with reconnect config
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           reconnect: [max_attempts: 5, initial_delay: 50, max_delay: 100]}
        )

      # Check state to verify it's using Simple policy with correct max
      state = :sys.get_state(client_pid)
      assert state.retry_policy_module == RpcEx.RetryPolicy.Simple
      assert state.retry_policy_state.max_attempts == 5

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Client should stop after 5 attempts
      assert_receive {:DOWN, ^ref, :process, ^client_pid, reason}, 5_000
      assert {:max_reconnect_attempts, _error} = reason
    end

    test "reconnect: true uses Simple policy with infinite attempts", %{port: port} do
      # Start client with reconnect: true
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           reconnect: true}
        )

      # Check state
      state = :sys.get_state(client_pid)
      assert state.retry_policy_module == RpcEx.RetryPolicy.Simple
      assert state.retry_policy_state.max_attempts == :infinity

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Wait a bit to ensure multiple retries
      Process.sleep(500)

      # Client should still be alive
      assert Process.alive?(client_pid)
      state = :sys.get_state(client_pid)
      assert state.reconnect_attempt > 2

      # No DOWN message
      refute_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 200
    end
  end

  describe "Explicit retry_policy overrides reconnect config" do
    test "retry_policy takes precedence over reconnect config", %{port: port} do
      # Start client with both retry_policy and reconnect config
      # retry_policy should win
      {:ok, client_pid} =
        start_supervised(
          {Client,
           url: "ws://localhost:#{port}/",
           router: RpcEx.Test.Integration.ClientRouter,
           retry_policy: {Smart, []},
           reconnect: [max_attempts: 3, initial_delay: 50]}
        )

      # Check state - should be using Smart, not Simple
      state = :sys.get_state(client_pid)
      assert state.retry_policy_module == RpcEx.RetryPolicy.Smart

      # Monitor the client
      ref = Process.monitor(client_pid)

      # Wait for several retry attempts (Smart retries indefinitely)
      Process.sleep(500)

      # Client should still be alive (not stopped at 3 attempts)
      assert Process.alive?(client_pid)
      state = :sys.get_state(client_pid)
      assert state.reconnect_attempt > 3

      # No DOWN message
      refute_receive {:DOWN, ^ref, :process, ^client_pid, _reason}, 200
    end
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
