defmodule RpcEx.RetryPolicy do
  @moduledoc """
  Behaviour for implementing custom retry policies for RpcEx client connections.

  A retry policy determines whether a disconnected client should attempt to reconnect
  or stop permanently based on the disconnect reason and connection history.

  ## Implementing a Retry Policy

  To create a custom retry policy, implement this behaviour:

      defmodule MyApp.CustomRetryPolicy do
        @behaviour RpcEx.RetryPolicy

        @impl true
        def initial_state(opts) do
          %{custom_config: Keyword.get(opts, :custom_config)}
        end

        @impl true
        def should_retry?(reason, attempt, state) do
          case reason do
            {:connection_failed, _} -> {:retry, state}
            {:auth_failed, _} -> {:stop, :authentication_failed}
            _ -> {:retry, state}
          end
        end
      end

  ## Built-in Policies

  - `RpcEx.RetryPolicy.Simple` - Simple max attempts counter (default)
  - `RpcEx.RetryPolicy.Smart` - Intelligent retry based on error type

  ## Usage

      # With Simple policy (max attempts)
      RpcEx.Client.start_link(
        url: "ws://localhost:4000",
        retry_policy: {RpcEx.RetryPolicy.Simple, max_attempts: 5}
      )

      # With Smart policy (error-based decisions)
      RpcEx.Client.start_link(
        url: "ws://localhost:4000",
        retry_policy: {RpcEx.RetryPolicy.Smart, [
          auth_failure_codes: [1002, 1008, 4001],
          on_fatal: :log
        ]}
      )

      # With custom policy
      RpcEx.Client.start_link(
        url: "ws://localhost:4000",
        retry_policy: {MyApp.CustomRetryPolicy, custom_config: "value"}
      )
  """

  @typedoc """
  The reason why the connection was disconnected.

  Common reasons include:
  - `{:connection_failed, error}` - Initial HTTP connection failed
  - `{:upgrade_failed, error}` - WebSocket upgrade failed
  - `{:websocket_new_failed, error}` - WebSocket initialization failed
  - `{:handshake_failed, reason}` - RPC protocol handshake failed
  - `{:remote_close, {code, message}}` - Server closed the connection
  - `{:stream_error, error}` - WebSocket stream error
  - `{:hello_failed, reason}` - Failed to send hello frame
  - `{:pong_failed, reason}` - Failed to respond to ping
  """
  @type disconnect_reason :: term()

  @typedoc """
  Custom state maintained by the retry policy across connection attempts.
  """
  @type state :: term()

  @typedoc """
  Decision whether to retry the connection.

  - `{:retry, new_state}` - Attempt to reconnect with updated state
  - `{:stop, reason}` - Stop the client GenServer with the given reason
  """
  @type retry_decision :: {:retry, state} | {:stop, reason :: term()}

  @doc """
  Initialize the retry policy state from the provided options.

  Called once when the client starts.
  """
  @callback initial_state(opts :: keyword()) :: state

  @doc """
  Decide whether to retry a connection after a disconnect.

  ## Parameters

  - `disconnect_reason` - Why the connection was lost
  - `attempt` - The reconnection attempt number (0-based, 0 = first reconnect)
  - `state` - The current retry policy state

  ## Returns

  - `{:retry, new_state}` - Proceed with reconnection
  - `{:stop, reason}` - Stop the client permanently
  """
  @callback should_retry?(disconnect_reason, attempt :: non_neg_integer(), state) ::
              retry_decision
end
