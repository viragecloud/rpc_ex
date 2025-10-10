# RPC-Ex Desired API Usage

This document sketches the developer experience we want to provide before implementation begins. All modules and functions referenced here are aspirational and serve as targets for the upcoming design work.

## Server Setup

```elixir
defmodule MyApp.RPC do
  use RpcEx.Router

  middleware MyApp.RPC.Logging

  call :echo, args: [:message] do
    {:ok, %{message: message, echoed_at: DateTime.utc_now()}}
  end

  call :delayed_echo, timeout: :timer.seconds(10) do
    Task.await(Task.async(fn -> do_work(args) end), opts.timeout_ms)
  end

  cast :notify_all do
    MyApp.Notifier.broadcast(args)
    :ok
  end
end

defmodule MyApp.RPCServer do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {RpcEx.Server,
       router: MyApp.RPC,
       port: 4444,
       transport: :bandit,
       compression: :enabled,
       discovery: true,
       max_inflight: 10_000,
       handshake: [token_validator: &MyApp.Auth.validate/1],
       telemetry_prefix: [:my_app, :rpc]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

- `use RpcEx.Router` compiles route metadata for discovery and reflection.
- `call` handlers receive `args`, `context`, and `opts` bindings; they return `{:ok, result}` or `{:error, reason}` tuples.
- Middleware modules implement `c:RpcEx.Router.Middleware.handle/3` for cross-cutting concerns (auth, tracing).

## Client Setup

```elixir
defmodule MyApp.RPCClient do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {RpcEx.Client,
       name: __MODULE__,
       url: "wss://rpc.myapp.test/socket",
       reconnect: [strategy: :exponential, max_delay: 5_000],
       compression: :enabled,
       timeout: 5_000,
       discovery: true,
       router: MyApp.ClientHandlers}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

The client wraps a Mint WebSocket connection, offering synchronous convenience functions and async callbacks.

## Client Handlers for Server-Initiated RPC

```elixir
defmodule MyApp.ClientHandlers do
  use RpcEx.Router

  call :flush_cache do
    MyApp.Cache.flush(args.scope)
    {:ok, :ok}
  end

  cast :invalidate do
    MyApp.Cache.invalidate(args.key)
    :ok
  end
end
```

## Performing Calls and Casts

```elixir
# synchronous call with timeout override
{:ok, user} =
  RpcEx.Client.call(MyApp.RPCClient, :get_user,
    args: %{id: 123},
    timeout: 7_500,
    meta: %{trace_id: trace_id()}
  )

# fire-and-forget cast
:ok =
  RpcEx.Client.cast(MyApp.RPCClient, :notify_all,
    args: %{message: "System maintenance"},
    meta: %{important: true}
  )

# async call returns reference for later await
ref = RpcEx.Client.call_async(MyApp.RPCClient, :heavy_job, args: %{payload: data})
{:ok, result} = RpcEx.Client.await(ref, 15_000)
```

## Discovering Available Routes

```elixir
# request reflection data from server
{:ok, routes} = RpcEx.Client.discover(MyApp.RPCClient)
[
  %{route: :echo, kind: :call, timeout_ms: 5_000, doc: "Echoes message"},
  %{route: :notify_all, kind: :cast}
]
```

On the server, a similar `RpcEx.Server.discover/1` API exposes available client handlers to facilitate bi-directional coordination.

## Telemetry & Observability

```elixir
:telemetry.attach_many(
  "rpc-observer",
  [
    [:rpc_ex, :client, :call, :start],
    [:rpc_ex, :client, :call, :stop],
    [:rpc_ex, :client, :call, :exception],
    [:rpc_ex, :server, :inflight, :dropped]
  ],
  &MyApp.RPCTelemetry.handle_event/4,
  []
)
```

Each event includes metadata such as `route`, `role`, `msg_id`, `timeout_ms`, and timing measurements.

## Error Handling Patterns

```elixir
case RpcEx.Client.call(MyApp.RPCClient, :dangerous_op, args: payload) do
  {:ok, result} ->
    process(result)

  {:error, :timeout} ->
    Logger.warn("RPC timed out", route: :dangerous_op)
    retry_later()

  {:error, {:remote, reason, detail}} ->
    Logger.error("Remote failure: #{inspect(reason)}", detail: detail)
    {:error, reason}
end
```

- Remote errors surface as tagged tuples distinguishing local failures (`:timeout`, `:disconnected`) from remote handler errors (`{:remote, reason, detail}`).
- Library should provide hooks for custom retry strategies (`RpcEx.Client.with_retry/2`).

## Supervision & Shutdown

```elixir
children = [
  MyApp.RPCServer,
  MyApp.RPCClient
]

opts = [strategy: :one_for_one, name: MyApp.Supervisor]
Supervisor.start_link(children, opts)
```

During shutdown, both client and server modules expose `stop/1` to flush in-flight calls gracefully and close WebSocket sessions, defaulting to a configurable grace period.

## Configuration Summary

- `RpcEx.Server` options:
  - `:router` (module) **required**
  - `:port` / `:url`
  - `:transport` (`:bandit` default)
  - `:compression` (`:enabled | :disabled`)
  - `:discovery` (boolean)
  - `:max_inflight` (integer)
  - `:timeout` (default per-call)
  - `:handshake` (keyword for auth/challenge)
  - `:telemetry_prefix` (list)

- `RpcEx.Client` options:
  - `:name` (Registry alias)
  - `:url`
  - `:router` (module for inbound RPC)
  - `:timeout`
  - `:compression`
  - `:discovery`
  - `:reconnect` (strategy options)
  - `:telemetry_prefix`
  - `:handshake` (auth metadata function)

These examples outline the ergonomic goals for the library: minimal boilerplate, clear supervision integration, explicit timeouts, discoverability, and full telemetry coverage.
