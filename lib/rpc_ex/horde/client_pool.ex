defmodule RpcEx.Horde.ClientPool do
  @moduledoc """
  Distributed pool of `RpcEx.Client` processes managed via Horde.

  The pool spins up `RpcEx.Client` connections under a `Horde.DynamicSupervisor`
  and registers each connection in a shared `Horde.Registry`. Entries are tagged
  with status metadata that allows callers to pick a healthy connection when
  issuing RPC calls or casts.

  ## Usage

      children = [
        RpcEx.Horde.registry_child_spec(name: MyApp.RpcRegistry, keys: :duplicate),
        RpcEx.Horde.client_supervisor_spec(name: MyApp.RpcSupervisor),
        {RpcEx.Horde.ClientPool,
         name: MyApp.RpcPool,
         registry: MyApp.RpcRegistry,
         supervisor: MyApp.RpcSupervisor,
         pool_key: {:rpc_ex, :clients, :upstream},
         pool_size: 4,
         client_opts: [url: "wss://example.com/rpc", router: MyApp.Router]}
      ]

  The pool API mirrors the regular client API but transparently load balances
  across the available WebSocket connections.
  """

  use GenServer

  require Logger

  alias Horde.DynamicSupervisor
  alias Horde.Registry
  alias RpcEx.Client

  @type option ::
          {:name, GenServer.name()}
          | {:registry, atom()}
          | {:supervisor, atom()}
          | {:pool_key, term()}
          | {:pool_size, pos_integer()}
          | {:client_opts, keyword()}
          | {:metadata, map() | keyword()}

  @type call_option :: Client.call_option()

  defstruct name: nil,
            registry: nil,
            supervisor: nil,
            pool_key: nil,
            pool_size: 0,
            client_opts: [],
            metadata: %{}

  @doc """
  Starts the client pool process.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the supervisor child specification for the pool.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      shutdown: 10_000
    }
  end

  @doc """
  Performs a synchronous RPC call against the pool.
  """
  @spec call(GenServer.name(), RpcEx.route(), [call_option()]) ::
          {:ok, term(), map()} | {:error, term()}
  def call(pool, route, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(pool, {:call, route, opts}, timeout)
  end

  @doc """
  Performs a cast across the pool.
  """
  @spec cast(GenServer.name(), RpcEx.route(), keyword()) :: :ok | {:error, term()}
  def cast(pool, route, opts \\ []) do
    GenServer.call(pool, {:cast, route, opts})
  end

  @doc """
  Issues a discovery request using any healthy client connection.
  """
  @spec discover(GenServer.name(), keyword()) ::
          {:ok, list(), map()} | {:error, term()}
  def discover(pool, opts \\ []) do
    GenServer.call(pool, {:discover, opts})
  end

  @doc """
  Returns the registered client processes along with their metadata.
  """
  @spec clients(GenServer.name()) :: list({pid(), map()})
  def clients(pool) do
    GenServer.call(pool, :clients)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    supervisor = Keyword.fetch!(opts, :supervisor)
    pool_size = Keyword.get(opts, :pool_size, System.schedulers_online())
    pool_key = Keyword.get(opts, :pool_key, {:rpc_ex, :clients, Keyword.fetch!(opts, :name)})
    client_opts = Keyword.fetch!(opts, :client_opts)
    metadata = opts |> Keyword.get(:metadata, %{}) |> Map.new()

    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      registry: registry,
      supervisor: supervisor,
      pool_key: pool_key,
      pool_size: pool_size,
      client_opts: client_opts,
      metadata: metadata
    }

    start_clients(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:call, route, opts}, _from, state) do
    with {:ok, pid} <- pick_client(state) do
      {:reply, Client.call(pid, route, opts), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cast, route, opts}, _from, state) do
    with {:ok, pid} <- pick_client(state) do
      {:reply, Client.cast(pid, route, opts), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discover, opts}, _from, state) do
    with {:ok, pid} <- pick_client(state) do
      {:reply, Client.discover(pid, opts), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clients, _from, state) do
    {:reply, registry_entries(state), state}
  end

  ## Internal helpers

  defp start_clients(%__MODULE__{pool_size: pool_size} = state) do
    Enum.each(1..pool_size, fn index ->
      start_client(state, index)
    end)
  end

  defp start_client(state, index) do
    horde_opts = %{
      registry: state.registry,
      key: state.pool_key,
      meta: state.metadata |> Map.put(:pool, state.name) |> Map.put(:index, index)
    }

    client_opts =
      state.client_opts
      |> Keyword.put(:name, client_name(state.name, index))
      |> Keyword.put(:horde, horde_opts)

    child_spec =
      Client.child_spec(client_opts)
      |> Map.put(:id, {:rpc_ex_client, state.name, index})

    case DynamicSupervisor.start_child(state.supervisor, child_spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :ignore} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to start RpcEx client #{inspect(index)} in pool #{inspect(state.name)}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp pick_client(state) do
    entries = registry_entries(state)

    ready = Enum.filter(entries, fn {_pid, meta} -> Map.get(meta, :status) == :ready end)

    case choose_client(ready, entries) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp choose_client([], []), do: {:error, :no_available_clients}
  defp choose_client([], entries), do: choose_client(entries)
  defp choose_client(entries, _all), do: choose_client(entries)

  defp choose_client(entries) do
    alive = Enum.filter(entries, fn {pid, _meta} -> Process.alive?(pid) end)

    case alive do
      [] -> {:error, :no_available_clients}
      list -> {:ok, Enum.random(list)}
    end
  end

  defp registry_entries(state) do
    state.registry
    |> Registry.match(state.pool_key, :_, [])
    |> Enum.filter(fn {pid, _meta} -> Process.alive?(pid) end)
  rescue
    _ -> []
  end

  defp client_name(name, index) when is_atom(name) do
    String.to_atom("#{name}.client_#{index}")
  end

  defp client_name(name, index), do: {:rpc_ex_client, name, index}
end
