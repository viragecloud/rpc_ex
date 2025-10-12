defmodule RpcEx.Server do
  @moduledoc """
  Bandit-based RPC server that terminates WebSocket connections and dispatches
  inbound messages to router-defined handlers.

  The server supervises connection processes, applies middleware, and manages
  the WebSocket lifecycle for bidirectional RPC communication.

  ## Example

      defmodule MyApp.Router do
        use RpcEx.Router

        call :ping do
          {:ok, %{pong: args[:ping]}}
        end
      end

      # In your application supervisor
      children = [
        {RpcEx.Server,
         router: MyApp.Router,
         port: 4000,
         context: %{service: :my_app}}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  - `:router` - (required) Module implementing RPC routes via `RpcEx.Router`
  - `:port` - Port to listen on (default: 4444)
  - `:scheme` - `:http` or `:https` (default: `:http`)
  - `:context` - Custom context map passed to all handlers
  - `:auth` - Authentication module `{module, opts}` implementing `RpcEx.Server.Auth`
  - `:horde` - Horde registration options for tracking inbound connections
  - `:handshake` - Options for protocol handshake negotiation
  - `:name` - Name for process registration

  For additional Bandit configuration options, see `Bandit.start_link/1`.

  ## Authentication

  Configure authentication to validate clients during handshake:

      RpcEx.Server.start_link(
        router: MyApp.Router,
        port: 4000,
        auth: {MyApp.TokenAuth, []}
      )

  See `RpcEx.Server.Auth` for implementing custom authentication.

  ## Bidirectional RPC

  Server handlers can initiate calls to the connected client using the `peer`
  handle injected into the handler context:

      call :server_to_client do
        {:ok, result, _meta} = RpcEx.Peer.call(context.peer, :client_method, args: %{foo: :bar})
        {:ok, result}
      end
  """

  alias Bandit
  alias RpcEx.Reflection

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
          | {:auth, {module(), keyword()}}
          | {:telemetry_prefix, [atom()]}
          | {:url, String.t()}
          | {:connection_options, keyword()}
          | {:horde, keyword()}

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
    name = Keyword.get(opts, :name)

    plug_opts = [
      router: router,
      handshake: Keyword.get(opts, :handshake, []),
      context: Keyword.get(opts, :context, %{}),
      auth: Keyword.get(opts, :auth),
      websocket: Keyword.get(opts, :connection_options, []),
      horde: Keyword.get(opts, :horde)
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
        port: port
      )

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} = ok ->
        maybe_register(name, pid)
        ok

      other ->
        other
    end
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

  defp maybe_register(nil, _pid), do: :ok

  defp maybe_register({:via, module, term}, pid) do
    module.register_name(term, pid)
  end

  defp maybe_register(name, pid) when is_atom(name) do
    Process.register(pid, name)
  rescue
    ArgumentError -> :ok
  end
end
