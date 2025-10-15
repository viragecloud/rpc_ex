defmodule RpcEx.RetryPolicy.SimpleTest do
  use ExUnit.Case, async: true

  alias RpcEx.RetryPolicy.Simple

  describe "initial_state/1" do
    test "defaults to infinite retries" do
      state = Simple.initial_state([])
      assert state.max_attempts == :infinity
    end

    test "accepts custom max_attempts" do
      state = Simple.initial_state(max_attempts: 5)
      assert state.max_attempts == 5
    end

    test "accepts 0 max_attempts (no retries)" do
      state = Simple.initial_state(max_attempts: 0)
      assert state.max_attempts == 0
    end
  end

  describe "should_retry?/3 with infinite retries" do
    setup do
      state = Simple.initial_state([])
      {:ok, state: state}
    end

    test "always retries regardless of reason", %{state: state} do
      reasons = [
        {:connection_failed, :econnrefused},
        {:handshake_failed, :timeout},
        {:remote_close, {1000, "Normal"}},
        {:remote_close, {1002, "Protocol error"}},
        {:stream_error, :closed}
      ]

      for reason <- reasons do
        for attempt <- 0..100 do
          assert {:retry, ^state} = Simple.should_retry?(reason, attempt, state)
        end
      end
    end
  end

  describe "should_retry?/3 with max_attempts" do
    test "retries up to max_attempts" do
      state = Simple.initial_state(max_attempts: 3)

      # Attempt 0, 1, 2 should retry
      assert {:retry, ^state} = Simple.should_retry?(:any_reason, 0, state)
      assert {:retry, ^state} = Simple.should_retry?(:any_reason, 1, state)
      assert {:retry, ^state} = Simple.should_retry?(:any_reason, 2, state)

      # Attempt 3 should stop
      assert {:stop, {:max_reconnect_attempts, :any_reason}} =
               Simple.should_retry?(:any_reason, 3, state)

      # Beyond max should also stop
      assert {:stop, {:max_reconnect_attempts, :another}} =
               Simple.should_retry?(:another, 4, state)
    end

    test "max_attempts: 0 never retries" do
      state = Simple.initial_state(max_attempts: 0)

      assert {:stop, {:max_reconnect_attempts, :reason}} =
               Simple.should_retry?(:reason, 0, state)
    end

    test "max_attempts: 1 retries once" do
      state = Simple.initial_state(max_attempts: 1)

      assert {:retry, ^state} = Simple.should_retry?(:reason, 0, state)

      assert {:stop, {:max_reconnect_attempts, :reason}} =
               Simple.should_retry?(:reason, 1, state)
    end
  end

  describe "should_retry?/3 treats all errors equally" do
    test "does not distinguish between error types" do
      state = Simple.initial_state(max_attempts: 2)

      # Auth error
      assert {:retry, ^state} =
               Simple.should_retry?({:remote_close, {1002, "auth failed"}}, 0, state)

      # Network error
      assert {:retry, ^state} =
               Simple.should_retry?({:connection_failed, :timeout}, 1, state)

      # Both hit max at attempt 2
      assert {:stop, _} = Simple.should_retry?({:remote_close, {1002, "auth"}}, 2, state)
      assert {:stop, _} = Simple.should_retry?({:connection_failed, :timeout}, 2, state)
    end
  end
end
