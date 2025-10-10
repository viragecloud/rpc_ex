defmodule RpcEx.Server do
  @moduledoc """
  Bandit-based RPC server that terminates WebSocket connections and dispatches
  inbound messages to router-defined handlers.

  The server supervises connection processes, applies middleware, manages
  backpressure, and emits telemetry signals. Implementation details will be
  developed incrementally; this module captures the intended public API.
  """

  @type option ::
          {:router, module()}
          | {:port, :inet.port_number()}
          | {:transport, :bandit | :cowboy}
          | {:compression, :enabled | :disabled}
          | {:discovery, boolean()}
          | {:max_inflight, pos_integer()}
          | {:timeout, non_neg_integer()}
          | {:handshake, keyword()}
          | {:telemetry_prefix, [atom()]}
          | {:url, String.t()}

  @doc """
  Starts the RPC server endpoint.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts) do
    {:error, :not_implemented}
  end

  @doc """
  Returns the supervisor child specification.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  @doc """
  Returns metadata about the routes handled by the configured router.
  """
  @spec describe(module()) :: %{calls: list(), casts: list()}
  def describe(_router) do
    %{calls: [], casts: []}
  end

  @doc """
  Invokes discovery against a connected client (placeholder).
  """
  @spec discover(pid(), keyword()) :: {:ok, list()} | {:error, term()}
  def discover(_connection_pid, _opts \\ []) do
    {:error, :not_implemented}
  end
end
