defmodule RpcEx.Server do
  @moduledoc """
  Bandit-based RPC server that terminates WebSocket connections and dispatches
  inbound messages to router-defined handlers.

  The server supervises connection processes, applies middleware, manages
  backpressure, and emits telemetry signals. Implementation details will be
  developed incrementally; this module captures the intended public API.
  """

  alias RpcEx.Reflection
  alias Bandit

  @type option ::
          {:router, module()}
          | {:port, :inet.port_number()}
          | {:scheme, :http | :https}
          | {:transport, :bandit | :cowboy}
          | {:compression, :enabled | :disabled}
          | {:discovery, boolean()}
          | {:max_inflight, pos_integer()}
          | {:timeout, non_neg_integer()}
          | {:handshake, keyword()}
          | {:context, map()}
          | {:telemetry_prefix, [atom()]}
          | {:url, String.t()}
          | {:connection_options, keyword()}

  @default_scheme :http
  @default_port 4444

  @doc """
  Starts the RPC server endpoint backed by Bandit.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    router = Keyword.fetch!(opts, :router)
    scheme = Keyword.get(opts, :scheme, @default_scheme)
    port = opts |> Keyword.get(:port, @default_port) |> normalize_port()
    name = Keyword.get(opts, :name, __MODULE__)

    plug_opts = [
      router: router,
      handshake: Keyword.get(opts, :handshake, []),
      context: Keyword.get(opts, :context, %{}),
      websocket: Keyword.get(opts, :connection_options, [])
    ]

    bandit_opts =
      opts
      |> Keyword.take([
        :ip,
        :transport_options,
        :thousand_island_options,
        :http_options,
        :websocket_options,
        :startup_log
      ])
      |> Keyword.merge(
        plug: {RpcEx.Server.Endpoint, plug_opts},
        scheme: scheme,
        port: port,
        name: name
      )

    Bandit.start_link(bandit_opts)
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
  def describe(router) when is_atom(router) do
    entries = Reflection.describe(router)

    %{
      calls: Enum.filter(entries, &(&1.kind == :call)) |> Enum.map(&Map.drop(&1, [:kind])),
      casts: Enum.filter(entries, &(&1.kind == :cast)) |> Enum.map(&Map.drop(&1, [:kind]))
    }
  end

  @doc """
  Invokes discovery against a connected client (placeholder).
  """
  @spec discover(pid(), keyword()) :: {:ok, list()} | {:error, term()}
  def discover(_connection_pid, _opts \\ []) do
    {:error, :not_implemented}
  end

  defp normalize_port(port) when is_integer(port), do: port
  defp normalize_port(port) when is_binary(port), do: String.to_integer(port)
  defp normalize_port(_), do: @default_port
end
