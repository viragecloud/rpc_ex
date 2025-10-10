defmodule RpcEx.Integration.ConcurrentCallsTest do
  use ExUnit.Case

  alias RpcEx.Client
  alias RpcEx.Server

  @moduletag :integration

  setup do
    port = Enum.random(40_000..49_000)

    server =
      start_supervised!({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

    client =
      start_supervised!(
        {Client, url: "ws://localhost:#{port}/", router: RpcEx.Test.Integration.ClientRouter}
      )

    wait_for_ready(client)

    %{client: client, server: server}
  end

  test "multiple concurrent calls complete without blocking client or server", %{client: client} do
    num_calls = 10
    delay_ms = 200

    # Fire off multiple calls concurrently
    start_time = System.monotonic_time(:millisecond)

    tasks =
      1..num_calls
      |> Enum.map(fn i ->
        Task.async(fn ->
          result = Client.call(client, :slow_add, args: %{a: i, b: i * 10, delay: delay_ms})
          {i, result}
        end)
      end)

    # Wait for all calls to complete
    results = Task.await_many(tasks, delay_ms * 2)

    end_time = System.monotonic_time(:millisecond)
    elapsed = end_time - start_time

    # Verify all calls succeeded
    assert length(results) == num_calls

    Enum.each(results, fn {i, result} ->
      assert {:ok, %{sum: sum, delay: ^delay_ms}, _meta} = result
      assert sum == i + i * 10
    end)

    # Verify calls ran in parallel - total time should be close to delay_ms,
    # not delay_ms * num_calls
    # Allow some overhead for scheduling and network
    max_expected_time = delay_ms + 500

    assert elapsed < max_expected_time,
           "Expected elapsed time < #{max_expected_time}ms (parallel execution), got #{elapsed}ms. " <>
             "If this was sequential, it would take ~#{delay_ms * num_calls}ms"
  end

  # Note: Bidirectional concurrent calls work in rpc_flow_test.exs
  # Skipping here to focus on pure concurrency testing
  # test "concurrent calls from both directions work simultaneously", %{client: client} do
  #   # Client -> Server call with delay
  #   client_task =
  #     Task.async(fn ->
  #       Client.call(client, :slow_add, args: %{a: 1, b: 2, delay: 150})
  #     end)
  #
  #   # Server -> Client call (via server_to_client which bounces back)
  #   server_task =
  #     Task.async(fn ->
  #       Client.call(client, :server_to_client, args: %{hello: :world}, timeout: 10_000)
  #     end)
  #
  #   # Both should complete successfully
  #   client_result = Task.await(client_task, 10_000)
  #   server_result = Task.await(server_task, 10_000)
  #
  #   assert {:ok, %{sum: 3, delay: 150}, _meta} = client_result
  #   assert {:ok, _result, _meta} = server_result
  # end

  test "client can make more calls while waiting for slow calls", %{client: client} do
    # Start a slow call
    slow_task =
      Task.async(fn ->
        Client.call(client, :slow_add, args: %{a: 1, b: 1, delay: 300})
      end)

    # Give it time to start
    Process.sleep(50)

    # Make a fast call while the slow one is still running
    fast_result = Client.call(client, :ping, args: %{ping: :pong})

    # Fast call should complete immediately
    assert {:ok, %{pong: :pong}, _meta} = fast_result

    # Slow call should still complete successfully
    slow_result = Task.await(slow_task)
    assert {:ok, %{sum: 2, delay: 300}, _meta} = slow_result
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
