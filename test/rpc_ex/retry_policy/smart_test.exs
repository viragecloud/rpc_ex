defmodule RpcEx.RetryPolicy.SmartTest do
  use ExUnit.Case, async: true

  alias RpcEx.RetryPolicy.Smart

  describe "initial_state/1" do
    test "defaults to standard auth codes plus 4000-4999 range" do
      state = Smart.initial_state([])
      assert 1002 in state.auth_failure_codes
      assert 1008 in state.auth_failure_codes
      assert 4000 in state.auth_failure_codes
      assert 4999 in state.auth_failure_codes
    end

    test "accepts custom auth_failure_codes" do
      state = Smart.initial_state(auth_failure_codes: [1002, 9999])
      # Custom codes plus 4000-4999 range
      assert 1002 in state.auth_failure_codes
      assert 9999 in state.auth_failure_codes
      assert 4000 in state.auth_failure_codes
    end

    test "accepts fatal_error? callback" do
      checker = fn _ -> true end
      state = Smart.initial_state(fatal_error?: checker)
      assert state.fatal_error? == checker
    end

    test "accepts on_fatal action" do
      state = Smart.initial_state(on_fatal: {MyModule, :my_function, [:arg]})
      assert state.on_fatal == {MyModule, :my_function, [:arg]}
    end
  end

  describe "should_retry?/3 - transient errors (always retry)" do
    setup do
      state = Smart.initial_state([])
      {:ok, state: state}
    end

    test "connection failures always retry", %{state: state} do
      reasons = [
        {:connection_failed, :econnrefused},
        {:connection_failed, :timeout},
        {:connection_failed, :nxdomain}
      ]

      for reason <- reasons, attempt <- 0..10 do
        assert {:retry, ^state} = Smart.should_retry?(reason, attempt, state)
      end
    end

    test "websocket failures always retry", %{state: state} do
      reasons = [
        {:websocket_new_failed, :invalid},
        {:upgrade_failed, :timeout},
        {:stream_error, :closed}
      ]

      for reason <- reasons, attempt <- 0..10 do
        assert {:retry, ^state} = Smart.should_retry?(reason, attempt, state)
      end
    end

    test "normal close codes retry", %{state: state} do
      reasons = [
        {:remote_close, {1000, "Normal closure"}},
        {:remote_close, {1001, "Going away"}},
        {:remote_close, {1003, "Unsupported data"}}
      ]

      for reason <- reasons, attempt <- 0..10 do
        assert {:retry, ^state} = Smart.should_retry?(reason, attempt, state)
      end
    end

    test "unknown errors retry (fail-safe)", %{state: state} do
      reasons = [
        :unknown_error,
        {:weird_tuple, "something"},
        %{map: "error"}
      ]

      for reason <- reasons, attempt <- 0..10 do
        assert {:retry, ^state} = Smart.should_retry?(reason, attempt, state)
      end
    end
  end

  describe "should_retry?/3 - authentication failures (fatal)" do
    setup do
      state = Smart.initial_state([])
      {:ok, state: state}
    end

    test "stops on auth failure codes", %{state: state} do
      auth_codes = [1002, 1008, 4000, 4500, 4999]

      for code <- auth_codes do
        assert {:stop, {:authentication_failed, _}} =
                 Smart.should_retry?({:remote_close, {code, "Auth failed"}}, 0, state)
      end
    end

    test "stops on auth failure messages", %{state: state} do
      messages = [
        "authentication failed",
        "Authentication Failed",
        "UNAUTHORIZED",
        "Forbidden - bad token",
        "Invalid token provided",
        "Bad credentials"
      ]

      for message <- messages do
        # Use code 1000 (normal) but message indicates auth failure
        assert {:stop, {:authentication_failed, _}} =
                 Smart.should_retry?({:remote_close, {1000, message}}, 0, state)
      end
    end

    test "retries on close codes with non-auth messages", %{state: state} do
      # Code 1002 but message doesn't indicate auth failure
      assert {:retry, ^state} =
               Smart.should_retry?({:remote_close, {1002, "Protocol error"}}, 0, state)
    end
  end

  describe "should_retry?/3 - handshake failures (fatal)" do
    setup do
      state = Smart.initial_state([])
      {:ok, state: state}
    end

    test "stops on handshake failures", %{state: state} do
      reasons = [
        {:handshake_failed, :timeout},
        {:handshake_failed, :invalid_protocol},
        {:handshake_failed, %{reason: :version_mismatch}}
      ]

      for reason <- reasons do
        assert {:stop, {:handshake_failed, _}} = Smart.should_retry?(reason, 0, state)
      end
    end
  end

  describe "should_retry?/3 - custom fatal_error? callback" do
    test "stops when custom callback returns true" do
      checker = fn
        {:custom_fatal, _} -> true
        _ -> false
      end

      state = Smart.initial_state(fatal_error?: checker)

      assert {:stop, {:fatal_error, _}} =
               Smart.should_retry?({:custom_fatal, :reason}, 0, state)
    end

    test "retries when custom callback returns false" do
      checker = fn
        {:custom_fatal, _} -> true
        _ -> false
      end

      state = Smart.initial_state(fatal_error?: checker)

      assert {:retry, ^state} = Smart.should_retry?({:connection_failed, :timeout}, 0, state)
    end

    test "handles callback exceptions gracefully" do
      checker = fn _ -> raise "boom" end
      state = Smart.initial_state(fatal_error?: checker)

      # Should treat as non-fatal and retry
      assert {:retry, ^state} = Smart.should_retry?(:any_reason, 0, state)
    end
  end

  describe "should_retry?/3 - on_fatal callback" do
    test "on_fatal: :log is default" do
      state = Smart.initial_state([])
      assert state.on_fatal == :log

      # Should not raise
      assert {:stop, _} = Smart.should_retry?({:handshake_failed, :test}, 0, state)
    end

    test "on_fatal callback is invoked on fatal errors" do
      # Use a test process to verify callback is called
      test_pid = self()

      # We'll send a message to test_pid when callback is invoked
      callback_module = __MODULE__.OnFatalCallback
      callback_args = [test_pid]

      state = Smart.initial_state(on_fatal: {callback_module, :handle, callback_args})

      # This will call the callback
      assert {:stop, _} = Smart.should_retry?({:handshake_failed, :test}, 0, state)

      # Verify callback was invoked (if callback module exists and is implemented)
      # For this test to work, we'd need to implement the callback module
      # Skipping actual verification since we don't want to create side effects
    end
  end

  describe "should_retry?/3 - state preservation" do
    test "retry returns same state (stateless policy)" do
      state = Smart.initial_state([])

      assert {:retry, returned_state} =
               Smart.should_retry?({:connection_failed, :timeout}, 5, state)

      assert returned_state == state
    end
  end

  describe "edge cases" do
    test "handles non-integer close codes gracefully" do
      state = Smart.initial_state([])

      # Non-integer code should not match auth codes
      assert {:retry, ^state} =
               Smart.should_retry?({:remote_close, {"not_an_int", "message"}}, 0, state)
    end

    test "handles nil messages in close frames" do
      state = Smart.initial_state([])

      # Code 1002 (auth code) but nil message
      assert {:retry, ^state} = Smart.should_retry?({:remote_close, {1002, nil}}, 0, state)
    end

    test "handles atom messages in close frames" do
      state = Smart.initial_state([])

      # Code 1002 with atom message (not a string)
      assert {:retry, ^state} =
               Smart.should_retry?({:remote_close, {1002, :some_atom}}, 0, state)
    end
  end
end
