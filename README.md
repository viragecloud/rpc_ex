# RpcEx

A bidirectional RPC-over-WebSocket library for Elixir that enables high-throughput, non-blocking communication between peers using ETF-encoded binary frames.

Built on modern Elixir tooling (Bandit for servers, Mint for clients) and following OTP design principles, RpcEx provides a declarative router DSL for defining both request/response and fire-and-forget endpoints.

## Features

- **Bidirectional RPC**: Both client and server can initiate calls and casts after connection establishment
- **ETF Binary Protocol**: All messages use `:erlang.term_to_binary/2` with optional compression for efficient wire format
- **Declarative Router DSL**: Clean, macro-based routing for `call` (request/response) and `cast` (fire-and-forget) handlers
- **Concurrent Execution**: Non-blocking call handling with supervised tasks - WebSocket process never blocks
- **Protocol Negotiation**: WebSocket subprotocol `rpc_ex.etf.v1` with handshake sequence for capability negotiation
- **Route Discovery**: Introspect available routes at runtime via reflection API
- **Middleware Support**: Composable middleware chain for cross-cutting concerns (auth, logging, etc.)
- **Pluggable Authentication**: Validate clients during handshake with custom auth modules
- **Reconnection**: Built-in exponential backoff reconnection strategy for clients
- **Type-Safe**: Comprehensive typespecs throughout for Dialyzer compatibility

## Installation

Add `rpc_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rpc_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Define a Router

```elixir
defmodule MyApp.RpcRouter do
  use RpcEx.Router

  # Define a call (request/response)
  call :add do
    a = args[:a]
    b = args[:b]
    {:ok, a + b}
  end

  # Define a cast (fire-and-forget)
  call :log_event do
    Logger.info("Event: #{inspect(args)}")
    :ok
  end
end
```

### Start a Server

```elixir
# In your application supervisor
children = [
  {RpcEx.Server,
   router: MyApp.RpcRouter,
   port: 4000,
   context: %{user_id: "server"}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Connect a Client

```elixir
# Start the client
{:ok, client} = RpcEx.Client.start_link(
  url: "ws://localhost:4000",
  router: MyApp.ClientRouter,  # Optional - only needed for bidirectional RPC
  context: %{user_id: "client"}
)

# Make a call
{:ok, result, _meta} = RpcEx.Client.call(client, :add, args: %{a: 1, b: 2})
# result => 3

# Send a cast
:ok = RpcEx.Client.cast(client, :log_event, args: %{type: :login})

# Discover available routes
{:ok, routes, _meta} = RpcEx.Client.discover(client)
```

## Bidirectional RPC

Both client and server can define routers and initiate calls to each other:

```elixir
# Server router
defmodule ServerRouter do
  use RpcEx.Router

  call :ping do
    # Server can call back to client using context.peer
    {:ok, result, _meta} = RpcEx.Peer.call(context.peer, :client_method, args: %{})
    {:ok, %{pong: :ping, client_said: result}}
  end
end

# Client router
defmodule ClientRouter do
  use RpcEx.Router

  call :client_method do
    {:ok, "Hello from client!"}
  end
end
```

## Authentication

Authenticate clients during the WebSocket handshake:

```elixir
# Define authentication module
defmodule MyApp.TokenAuth do
  @behaviour RpcEx.Server.Auth

  def authenticate(credentials, _opts) do
    case validate_token(credentials) do
      {:ok, user} ->
        # Context available to all handlers
        {:ok, %{user: user, user_id: user.id, roles: user.roles}}

      {:error, reason} ->
        {:error, :invalid_token, reason}
    end
  end

  defp validate_token(%{"token" => token}), do: MyApp.Accounts.verify_token(token)
  defp validate_token(_), do: {:error, "Missing token"}
end

# Configure server with auth
{:ok, _server} = RpcEx.Server.start_link(
  router: MyApp.Router,
  port: 4000,
  auth: {MyApp.TokenAuth, []}
)

# Clients pass credentials in handshake
{:ok, client} = RpcEx.Client.start_link(
  url: "ws://localhost:4000",
  handshake: [
    meta: %{
      "auth" => %{
        "token" => "your-jwt-token-here"
      }
    }
  ]
)

# Handlers access authenticated context
call :get_profile do
  user_id = context.user_id  # From auth module
  {:ok, MyApp.Users.get_profile(user_id)}
end
```

See `RpcEx.Server.Auth` for detailed documentation.

## Middleware

Add cross-cutting concerns with middleware:

```elixir
defmodule MyApp.AuthMiddleware do
  @behaviour RpcEx.Router.Middleware

  def call(context, next_middleware, opts) do
    required_role = Keyword.get(opts, :role)

    if authorized?(context, required_role) do
      next_middleware.(context)
    else
      {:error, :unauthorized}
    end
  end
end

defmodule MyApp.Router do
  use RpcEx.Router

  middleware MyApp.AuthMiddleware, role: :admin

  call :delete_user do
    # Only executed if AuthMiddleware passes
    {:ok, :deleted}
  end
end
```

## Concurrency

RpcEx is designed for high concurrency:

- **Non-blocking**: Handlers execute in supervised tasks; WebSocket process never blocks
- **Parallel calls**: Multiple calls can be in-flight simultaneously from the same client
- **No head-of-line blocking**: Slow handlers don't block fast ones

```elixir
# These 10 calls execute in parallel, not sequentially
tasks = for i <- 1..10 do
  Task.async(fn ->
    RpcEx.Client.call(client, :slow_operation, args: %{id: i})
  end)
end

results = Task.await_many(tasks)
```

## Protocol

RpcEx uses a custom binary protocol over WebSocket:

1. **Connection**: Client initiates WebSocket upgrade with subprotocol `rpc_ex.etf.v1`
2. **Handshake**: Client sends `:hello` frame, server responds with `:welcome`
3. **RPC**: Peers exchange `:call`, `:cast`, `:reply`, and `:error` frames
4. **Encoding**: All frames use ETF (`:erlang.term_to_binary/2`) with optional compression

See `docs/protocol.md` for detailed protocol specification.

## Architecture

### Key Modules

- **`RpcEx.Client`** - GenServer-based client managing Mint WebSocket connection
- **`RpcEx.Server`** - Bandit-based WebSocket server with connection supervision
- **`RpcEx.Router`** - DSL for defining call/cast handlers with middleware
- **`RpcEx.Protocol.Frame`** - Frame encoding/decoding with ETF codec
- **`RpcEx.Protocol.Handshake`** - Protocol negotiation logic
- **`RpcEx.Peer`** - Handle for bidirectional RPC from handlers
- **`RpcEx.Reflection`** - Runtime introspection of router routes

### Message Flow

```
Client                          Server
  |-------- WebSocket Upgrade ------->|
  |<------- 101 Switching Protocols --|
  |                                    |
  |-------- :hello frame ------------>|
  |<------- :welcome frame ------------|
  |                                    |
  |-------- :call frame ------------->|
  |         (spawns handler task)      |
  |<------- :reply frame --------------|
  |                                    |
  |<------- :call frame --------------|
  |         (spawns handler task)      |
  |-------- :reply frame ------------>|
```

## Testing

RpcEx includes comprehensive unit and integration tests:

```bash
# Run all tests
mix test

# Run only integration tests
mix test --only integration

# Run with coverage
mix test --cover
```

## Documentation

Generate documentation with ExDoc:

```bash
mix deps.get
mix docs
open doc/index.html
```

## Development Status

RpcEx is under active development. Core protocol, router DSL, and bidirectional RPC are functional and tested. See `docs/project_plan.md` for the full development roadmap.

### Current Status: Phase 3 - Client & Server APIs

- ✅ Protocol & Codec
- ✅ Router DSL with middleware
- ✅ Bidirectional RPC
- ✅ Client reconnection logic
- ✅ Concurrent call handling
- 🚧 Telemetry instrumentation
- 📋 Production hardening (rate limiting, backpressure)

## Contributing

This project follows OTP design principles and emphasizes:

- Non-blocking, concurrent execution
- Comprehensive test coverage
- Type specifications for all public APIs
- Clean code style (enforced by Credo)

Run quality checks before committing:

```bash
mix check  # Runs format check, credo, and tests
```

## License

Copyright © 2025 Virage

---

For detailed guides and API documentation, see the [generated documentation](doc/index.html) or visit [HexDocs](https://hexdocs.pm/rpc_ex) (once published).
