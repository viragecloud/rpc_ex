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
       auth: {MyApp.Auth, []},
       context: %{server_id: "main"},
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
       router: MyApp.ClientHandlers,
       context: %{client_id: "app-1"},
       handshake: [
         meta: %{
           "auth" => %{
             "token" => get_auth_token()
           },
           "version" => "1.0.0"
         }
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp get_auth_token do
    # Retrieve token from environment, config, or secure storage
    System.get_env("RPC_AUTH_TOKEN")
  end
end
```

The client wraps a Mint WebSocket connection, offering synchronous convenience functions and async callbacks.

### Authentication

Clients pass credentials in the `:handshake` option's `meta` field under the `"auth"` key. The structure is application-defined and must match what the server's auth module expects:

```elixir
# Token-based authentication
handshake: [
  meta: %{
    "auth" => %{"token" => "jwt-token-here"}
  }
]

# Username/password authentication
handshake: [
  meta: %{
    "auth" => %{
      "username" => "alice",
      "password" => "secret123"
    }
  }
]

# API key authentication
handshake: [
  meta: %{
    "auth" => %{"api_key" => "sk_live_..."}
  }
]
```

If authentication fails, the client connection will be terminated and can automatically reconnect with the same credentials (if reconnection is enabled).

## Implementing Server Authentication

Create an authentication module implementing the `RpcEx.Server.Auth` behaviour:

```elixir
defmodule MyApp.Auth do
  @behaviour RpcEx.Server.Auth

  @impl true
  def authenticate(credentials, _opts) do
    case credentials do
      # Token-based authentication
      %{"token" => token} ->
        case MyApp.Accounts.verify_token(token) do
          {:ok, user} ->
            {:ok, %{
              user_id: user.id,
              username: user.username,
              roles: user.roles,
              authenticated: true
            }}

          {:error, :invalid_token} ->
            {:error, :invalid_credentials, "Invalid or expired token"}

          {:error, reason} ->
            {:error, :authentication_failed, reason}
        end

      # Username/password authentication
      %{"username" => username, "password" => password} ->
        case MyApp.Accounts.authenticate(username, password) do
          {:ok, user} ->
            {:ok, %{
              user_id: user.id,
              username: username,
              roles: user.roles,
              authenticated: true
            }}

          {:error, _} ->
            {:error, :invalid_credentials, "Invalid username or password"}
        end

      # Missing credentials
      _ ->
        {:error, :missing_credentials, "No authentication credentials provided"}
    end
  end
end
```

The context returned by `authenticate/2` is merged into the handler context, making it available to all route handlers:

```elixir
defmodule MyApp.RPC do
  use RpcEx.Router

  call :get_profile do
    # Auth context is available
    user_id = context.user_id

    case MyApp.Accounts.get_profile(user_id) do
      {:ok, profile} -> {:ok, profile}
      {:error, _} -> {:error, :not_found}
    end
  end

  call :admin_action do
    # Check roles from auth context
    if :admin in context.roles do
      perform_admin_action(args)
      {:ok, :success}
    else
      {:error, :forbidden}
    end
  end
end
```

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

# concurrent calls using standard Elixir Task API
tasks = [
  Task.async(fn -> RpcEx.Client.call(MyApp.RPCClient, :get_user, args: %{id: 1}) end),
  Task.async(fn -> RpcEx.Client.call(MyApp.RPCClient, :get_user, args: %{id: 2}) end),
  Task.async(fn -> RpcEx.Client.call(MyApp.RPCClient, :get_user, args: %{id: 3}) end)
]

results = Task.await_many(tasks, 5_000)
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
- Retry strategies can be implemented using standard Elixir patterns (e.g., recursive functions with exponential backoff, libraries like `Retry`).

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

### `RpcEx.Server` Options

- `:router` (module) - **Required**. Router module defining call/cast handlers
- `:port` (integer) - Port to listen on (default: 4000)
- `:scheme` (`:http | :https`) - Protocol scheme (default: `:http`)
- `:auth` (`{module(), keyword()}`) - Authentication module and options
- `:context` (map) - Base context merged into all handler contexts
- `:handshake` (keyword) - Additional handshake configuration
  - `:protocol_version` (integer) - Protocol version to advertise
  - `:capabilities` (list of atoms) - Capabilities to advertise
  - `:compression` (`:enabled | :disabled`) - Enable compression
  - `:supported_encodings` (list) - Supported encodings (default: `[:etf]`)
  - `:meta` (map) - Additional metadata in handshake
- `:telemetry_prefix` (list) - Telemetry event prefix

### `RpcEx.Client` Options

- `:url` (string) - **Required**. WebSocket URL (`ws://` or `wss://`)
- `:router` (module) - Optional router for server-initiated RPC
- `:context` (map) - Base context for handlers
- `:handshake` (keyword) - Handshake configuration
  - `:protocol_version` (integer) - Protocol version to request
  - `:capabilities` (list) - Capabilities to advertise
  - `:compression` (`:enabled | :disabled`) - Enable compression
  - `:enable_notifications` (boolean) - Enable notification capability
  - `:meta` (map) - Metadata including `"auth"` for credentials
- `:reconnect` (boolean) - Enable automatic reconnection (default: `true`)
- `:name` (atom) - Optional process name for registration

### Authentication Configuration

Server authentication is configured via the `:auth` option:

```elixir
# Basic auth module
auth: {MyApp.Auth, []}

# Auth module with options
auth: {MyApp.Auth, [valid_token: "secret", timeout: 5000]}

# No authentication
auth: nil  # or omit the option
```

Client credentials are passed via handshake metadata:

```elixir
handshake: [
  meta: %{
    "auth" => %{"token" => "..."}
  }
]
```

These examples reflect the actual implemented API for the library: minimal boilerplate, clear supervision integration, pluggable authentication, and comprehensive protocol support.
