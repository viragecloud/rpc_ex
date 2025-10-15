# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RpcEx is a bidirectional RPC-over-WebSocket library for Elixir. It enables high-throughput, non-blocking communication between peers using ETF-encoded binary frames over WebSocket connections. The library is built on modern Elixir tooling (Bandit for servers, Mint for clients) and follows OTP design principles.

### Core Concepts

- **Bidirectional RPC**: Both client and server can initiate calls and casts after connection establishment
- **ETF Encoding**: All messages use `:erlang.term_to_binary/2` with compression enabled by default
- **Router DSL**: Declarative macro-based routing for defining `call` (request/response) and `cast` (fire-and-forget) handlers
- **Protocol Negotiation**: WebSocket subprotocol `rpc_ex.etf.v1` with handshake sequence (`:hello`/`:welcome`)
- **Discovery**: Routes can be introspected at runtime via the reflection API

## Commands

### Development

```bash
# Install dependencies
mix deps.get

# Run all tests
mix test

# Run a single test file
mix test test/path/to/test.exs

# Run a specific test
mix test test/path/to/test.exs:42

# Run integration tests only
mix test test/integration/

# Format code
mix format

# Check code style and run tests
mix check

# Run credo linting
mix credo --strict

# Run dialyzer (type checking)
mix dialyzer

# Generate documentation
mix docs
```

### Testing Patterns

- Unit tests live in `test/` mirroring the `lib/` structure
- Integration tests are in `test/integration/` and spin up real server/client pairs
- Test support modules in `test/support/` and `test/integration/support/`
- Use `ExUnit.CaseTemplate` patterns for shared test setup (see existing integration tests)

## Architecture

### Message Flow

1. **Connection Establishment**:
   - Client initiates WebSocket upgrade with subprotocol `rpc_ex.etf.v1`
   - Client sends `:hello` frame with capabilities, compression settings
   - Server responds with `:welcome` frame confirming negotiated parameters
   - Both peers transition to `:ready` state and can exchange RPC messages

2. **RPC Invocation** (`:call` or `:cast`):
   - Sender encodes message using `RpcEx.Protocol.Frame` → `RpcEx.Codec` → ETF binary
   - Message dispatched over WebSocket as binary frame
   - Receiver decodes frame and routes to appropriate handler via `RpcEx.Router.Executor`
   - For calls: handler result packaged as `:reply` or `:error` frame and sent back
   - For casts: handler executes without replying

3. **Frame Structure**:
   - All frames are tuples: `{type :: atom(), version :: pos_integer(), payload :: map()}`
   - Common message types: `:hello`, `:welcome`, `:call`, `:cast`, `:reply`, `:error`, `:notify`, `:discover`, `:discover_reply`, `:heartbeat`

### Key Modules

#### Protocol Layer

- **`RpcEx.Protocol.Frame`**: Struct representing a protocol message; provides `encode/decode` via `RpcEx.Codec`
- **`RpcEx.Protocol.Handshake`**: Handles `:hello`/`:welcome` negotiation and session setup
- **`RpcEx.Codec`**: ETF encode/decode with compression and safe mode defaults

#### Routing & Execution

- **`RpcEx.Router`**: DSL macro module for defining routes with `call` and `cast` blocks
  - Routes captured in `@rpc_routes` module attribute at compile time
  - Middleware chain built incrementally as routes are declared
  - Router modules expose `__rpc_dispatch__/5` callback for runtime invocation
- **`RpcEx.Router.Route`**: Struct holding route metadata (name, kind, handler, options, middlewares)
- **`RpcEx.Router.Executor`**: Dispatches incoming frames to router handlers, applying middleware
- **`RpcEx.Router.Middleware`**: Behavior for middleware implementations
- **`RpcEx.Reflection`**: Introspects router modules to generate discovery metadata

#### Server Side

- **`RpcEx.Server`**: Public API for starting Bandit-based RPC server
  - Accepts router module, port, scheme, handshake options, context
  - Returns supervisor-compatible child spec
- **`RpcEx.Server.Endpoint`**: Plug that upgrades HTTP connections to WebSocket
- **`RpcEx.Server.WebSocketHandler`**: Bandit WebSocket handler managing per-connection lifecycle
- **`RpcEx.Server.Connection`**: State machine for server-side connection, handles incoming frames

#### Client Side

- **`RpcEx.Client`**: GenServer-based client managing Mint WebSocket connection
  - Lifecycle: `:connecting` → `:awaiting_upgrade` → `:awaiting_welcome` → `:ready`
  - Tracks pending calls in `%{msg_id => %{from:, timer:, type:}}` map
  - Supports `call/3`, `cast/3`, `discover/2` operations
  - Pluggable retry policies via `:retry_policy` option
- **`RpcEx.Client.Connection`**: Encapsulates client connection state, mirrors server connection responsibilities
- **`RpcEx.RetryPolicy`**: Behavior for custom retry decision logic
- **`RpcEx.RetryPolicy.Simple`**: Simple max-attempts retry policy
- **`RpcEx.RetryPolicy.Smart`**: Intelligent error-based retry policy (stops on auth failures, retries on network errors)

#### Runtime & Utilities

- **`RpcEx.Runtime.Dispatcher`**: Coordinates handler task execution with telemetry and timeouts
- **`RpcEx.Transport`**: Abstraction layer for future transport adapters (currently WebSocket-only)

### Router DSL Usage

Routers are defined using the `RpcEx.Router` DSL:

```elixir
defmodule MyApp.RpcRouter do
  use RpcEx.Router

  # Apply middleware to subsequent routes
  middleware MyApp.AuthMiddleware, roles: [:admin]

  # Define a call (request/response)
  call :add, timeout: 5_000 do
    # `args`, `context`, and `opts` are injected variables
    a = args[:a]
    b = args[:b]
    {:ok, a + b}
  end

  # Define a cast (fire-and-forget)
  cast :log_event do
    Logger.info("Received event: #{inspect(args)}")
    :ok
  end
end
```

- Routes compile to `__rpc_dispatch__/5` clauses with pattern matching on `kind` and `route` name
- Middleware chain frozen at route definition time and stored in route metadata
- `context` contains connection-level state (session, peer info)
- Return `{:ok, result}` for successful calls, `{:error, reason}` for failures
- Casts can return `:ok`, `{:notify, payload}` to push events back

### Connection State Management

Both server and client maintain a connection struct with:

- **`:router`**: Module defining available routes
- **`:session`**: Negotiated parameters from handshake (protocol version, compression, capabilities)
- **`:context`**: User-provided context map passed to handlers
- **`:pending`**: (Client only) Map of in-flight calls awaiting replies

Connections are stateful GenServers that:

1. Handle frame encode/decode
2. Dispatch to router executor
3. Manage timeouts and reply correlation
4. Emit telemetry events

### Middleware System

Middleware modules implement `RpcEx.Router.Middleware` behavior:

```elixir
defmodule MyApp.Middleware do
  @behaviour RpcEx.Router.Middleware

  def call(context, next_middleware, _opts) do
    # Pre-processing
    result = next_middleware.(context)
    # Post-processing
    result
  end
end
```

Middleware is applied in order, wrapping the handler execution. Each middleware receives the context, the next middleware function in the chain, and options.

### Testing Integration

Integration tests follow this pattern:

1. Define test-specific routers in `test/integration/support/`
2. Start server with `RpcEx.Server.start_link(router: ServerRouter, port: port)`
3. Start client with `RpcEx.Client.start_link(url: "ws://localhost:#{port}", router: ClientRouter)`
4. Use `RpcEx.Client.call/3` or `RpcEx.Client.cast/3` to exercise routes
5. Verify responses and track side effects via test helpers (e.g., `Tracker` GenServer)

See `test/integration/rpc_flow_test.exs` for examples.

## Important Notes

- **Non-blocking Execution**: Handlers run in supervised tasks; never block the WebSocket process
- **ETF Safety**: Decoder runs in `:safe` mode by default to prevent arbitrary function execution
- **Compression**: Enabled by default via `compressed: 6` option; can be negotiated off during handshake
- **Timeouts**: Per-call timeouts enforced client-side with `Process.send_after`; late replies are dropped
- **Discovery**: Router introspection via `RpcEx.Reflection.describe/1` or runtime `:discover` message
- **Retry Policies**: Pluggable retry decision logic; use `RpcEx.RetryPolicy.Smart` for production (fail-fast on auth errors, retry on network issues)
- **Telemetry**: Events emitted for connection lifecycle, call start/stop/error (planned but not yet fully instrumented)

## Project Status

This project is under active development (Phase 2-3 of the project plan). Core protocol and router DSL are functional. Current work focuses on:

- Client2 implementation refinement
- Bidirectional RPC testing and stabilization
- Telemetry instrumentation
- Error handling and reconnection logic

See `docs/project_plan.md` for full development roadmap.

## Additional Documentation

- `docs/protocol.md`: Detailed WebSocket protocol specification
- `docs/project_plan.md`: Development phases, milestones, and design principles
- Generated docs: Run `mix docs` and open `doc/index.html`
