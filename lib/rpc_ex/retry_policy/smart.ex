defmodule RpcEx.RetryPolicy.Smart do
  @moduledoc """
  An intelligent retry policy that makes decisions based on disconnect reason.

  This policy distinguishes between:
  - **Transient errors** (network issues, server restarts) - Retry indefinitely
  - **Fatal errors** (authentication, protocol errors) - Stop immediately

  ## Strategy

  ### Errors that trigger immediate stop (non-retryable):
  - Authentication failures (WebSocket close codes 1002, 1008, 4000-4999)
  - Handshake/protocol negotiation failures
  - Custom fatal error patterns (via `:fatal_error?` callback)

  ### Errors that retry indefinitely:
  - Connection failures (network errors)
  - WebSocket upgrade failures
  - Stream errors
  - All other unknown errors (fail-safe: retry)

  ## Options

  - `:auth_failure_codes` - List of WebSocket close codes that indicate auth failure
    (default: `[1002, 1008]` plus all 4000-4999 range)
  - `:fatal_error?` - Optional 1-arity function `(reason -> boolean())` to identify
    custom fatal errors that should stop retries
  - `:on_fatal` - Action when fatal error detected:
    - `:log` (default) - Log error only
    - `{module, function, args}` - Call `apply(module, function, [reason | args])`

  ## Examples

      # Default configuration
      {RpcEx.RetryPolicy.Smart, []}

      # Custom auth failure codes
      {RpcEx.RetryPolicy.Smart,
        auth_failure_codes: [1002, 1008, 4001, 4002]
      }

      # Custom fatal error matcher
      {RpcEx.RetryPolicy.Smart,
        fatal_error?: fn
          {:handshake_failed, %{reason: :bad_config}} -> true
          _ -> false
        end
      }

      # Custom action on fatal error
      {RpcEx.RetryPolicy.Smart,
        on_fatal: {MyApp.ErrorHandler, :handle_fatal_disconnect, []}
      }

  ## Complete Example

      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [
            {RpcEx.Client,
             url: "wss://api.example.com",
             router: MyApp.Router,
             retry_policy: {RpcEx.RetryPolicy.Smart, [
               auth_failure_codes: [1002, 1008, 4001],
               fatal_error?: &MyApp.is_config_error?/1,
               on_fatal: {MyApp.Notifier, :alert, [:critical]}
             ]}}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
  """

  @behaviour RpcEx.RetryPolicy

  require Logger

  @default_auth_codes [1002, 1008]
  @custom_auth_range 4000..4999

  @impl true
  def initial_state(opts) do
    auth_codes = Keyword.get(opts, :auth_failure_codes, @default_auth_codes)

    %{
      auth_failure_codes: auth_codes ++ Enum.to_list(@custom_auth_range),
      fatal_error?: Keyword.get(opts, :fatal_error?),
      on_fatal: Keyword.get(opts, :on_fatal, :log)
    }
  end

  @impl true
  def should_retry?(reason, attempt, state) do
    cond do
      # Check if it's an authentication failure (fatal)
      auth_failure?(reason, state) ->
        handle_fatal_error(reason, :authentication_failed, attempt, state)

      # Check if it's a handshake failure (fatal)
      handshake_failure?(reason) ->
        handle_fatal_error(reason, :handshake_failed, attempt, state)

      # Check custom fatal error matcher
      custom_fatal_error?(reason, state) ->
        handle_fatal_error(reason, :fatal_error, attempt, state)

      # All other errors are considered transient - retry indefinitely
      true ->
        Logger.debug(
          "Smart retry policy: transient error at attempt #{attempt}, will retry: #{inspect(reason)}"
        )

        {:retry, state}
    end
  end

  ## Fatal Error Detection

  defp auth_failure?({:remote_close, {code, message}}, _state) when is_integer(code) do
    # Check if the message itself indicates auth failure
    if auth_message?(message) do
      true
    else
      # Otherwise, only trust codes in the custom range (4000-4999)
      # Standard codes (1002, 1008) require auth-related message
      code in @custom_auth_range
    end
  end

  defp auth_failure?(_, _), do: false

  defp auth_message?(msg) when is_binary(msg) do
    msg_lower = String.downcase(msg)

    String.contains?(msg_lower, "auth") or
      String.contains?(msg_lower, "unauthorized") or
      String.contains?(msg_lower, "forbidden") or
      String.contains?(msg_lower, "invalid token") or
      String.contains?(msg_lower, "bad credentials")
  end

  defp auth_message?(_), do: false

  defp handshake_failure?({:handshake_failed, _}), do: true
  defp handshake_failure?(_), do: false

  defp custom_fatal_error?(_reason, %{fatal_error?: nil}), do: false

  defp custom_fatal_error?(reason, %{fatal_error?: checker}) when is_function(checker, 1) do
    try do
      checker.(reason)
    rescue
      e ->
        Logger.error(
          "Smart retry policy: fatal_error? callback raised: #{inspect(e)}, treating as non-fatal"
        )

        false
    end
  end

  ## Fatal Error Handling

  defp handle_fatal_error(reason, category, attempt, state) do
    Logger.error("""
    Smart retry policy: Fatal error detected at attempt #{attempt}
    Category: #{category}
    Reason: #{inspect(reason)}
    Client will stop and not retry.
    """)

    execute_on_fatal(reason, state)
    {:stop, {category, reason}}
  end

  defp execute_on_fatal(_reason, %{on_fatal: :log}), do: :ok

  defp execute_on_fatal(reason, %{on_fatal: {module, function, args}}) do
    try do
      apply(module, function, [reason | args])
    rescue
      e ->
        Logger.error(
          "Smart retry policy: on_fatal callback failed: #{inspect(e)}, continuing with stop"
        )
    end
  end

  defp execute_on_fatal(_, _), do: :ok
end
