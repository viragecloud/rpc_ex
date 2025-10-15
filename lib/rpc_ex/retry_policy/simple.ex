defmodule RpcEx.RetryPolicy.Simple do
  @moduledoc """
  A simple retry policy that retries up to a maximum number of attempts.

  This policy retries all disconnect reasons equally until the maximum
  attempt count is reached. It does not differentiate between transient
  network errors and permanent configuration issues.

  ## Options

  - `:max_attempts` - Maximum number of reconnection attempts (default: `:infinity`)

  ## Examples

      # Retry indefinitely (default)
      {RpcEx.RetryPolicy.Simple, []}

      # Retry up to 5 times
      {RpcEx.RetryPolicy.Simple, max_attempts: 5}

      # Never retry
      {RpcEx.RetryPolicy.Simple, max_attempts: 0}
  """

  @behaviour RpcEx.RetryPolicy

  require Logger

  @impl true
  def initial_state(opts) do
    %{
      max_attempts: Keyword.get(opts, :max_attempts, :infinity)
    }
  end

  @impl true
  def should_retry?(_reason, attempt, %{max_attempts: :infinity} = state) do
    Logger.debug("Simple retry policy: retrying attempt #{attempt} (max: infinity)")
    {:retry, state}
  end

  def should_retry?(reason, attempt, %{max_attempts: max} = state) when attempt < max do
    Logger.debug(
      "Simple retry policy: retrying attempt #{attempt}/#{max} for reason: #{inspect(reason)}"
    )

    {:retry, state}
  end

  def should_retry?(reason, attempt, %{max_attempts: max} = _state) do
    Logger.warning(
      "Simple retry policy: max attempts (#{max}) reached at attempt #{attempt}, " <>
        "stopping due to: #{inspect(reason)}"
    )

    {:stop, {:max_reconnect_attempts, reason}}
  end
end
