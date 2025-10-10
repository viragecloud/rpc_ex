# RpcEx WebSocket Protocol Specification

## Goals
- Provide a bidirectional RPC transport over WebSockets using ETF-encoded binary frames.
- Support both request/response (`call`) and fire-and-forget (`cast`) semantics initiated by either peer after connection establishment.
- Offer feature negotiation, compression, and discoverability while remaining implementation agnostic.
- Ensure non-blocking behaviour by keeping transport messages lightweight and delegating work to supervised processes.

## Terminology
- **Client**: The peer that initiates the WebSocket connection.
- **Server**: The peer that accepts the WebSocket upgrade.
- **Peer**: Either side of the connection; once connected both act symmetrically for RPC.
- **Session**: A live WebSocket connection with agreed parameters.
- **Envelope**: The encoded tuple carried inside each WebSocket frame.

## Transport
- WebSocket subprotocol: `rpc_ex.etf.v1`.
- Frames: binary opcode (`:binary`) containing ETF-encoded data via `:erlang.term_to_binary/2` (`compressed: 6`, `minor_version: 1` by default).
- All frames MUST be strictly monotonic; each carries a `msg_id` to correlate replies.
- Compression: Enforced by default; peers may negotiate to disable during handshake.
- Maximum frame size is configurable; peers SHOULD drop frames exceeding configured limits.

## Handshake Sequence
1. **Client** initiates WebSocket connection requesting subprotocol `rpc_ex.etf.v1` and sends an initial `hello` envelope immediately after upgrade:
   ```elixir
   {:hello, map()}
   ```
   Attributes include:
   - `protocol_version` (integer, default `1`)
   - `supported_encodings` (`[:etf]`)
   - `compression` (`:enabled | :disabled`)
   - `capabilities` (list of atoms, e.g. `[:calls, :casts, :discover]`)
   - `meta` (map of optional fields like auth tokens)
2. **Server** responds with `{:welcome, map()}` confirming negotiated parameters and optionally overriding compression or features. Server may reject with `{:close, reason_atom, meta}` resulting in immediate termination.
3. Upon `:welcome`, both peers may begin emitting RPC frames according to the agreed capabilities.

## Envelope Format

All operational frames follow the tuple shape:

```elixir
{type :: atom(), version :: pos_integer(), payload :: map()}
```

- `type`: one of `:call`, `:cast`, `:reply`, `:error`, `:notify`, `:discover`, `:discover_reply`, `:heartbeat`.
- `version`: message schema version (currently `1`). Allows forwards compatibility.
- `payload`: Type-specific map, documented below. Extra keys MUST be ignored to preserve compatibility.

### Common Payload Keys
- `msg_id` (binary): Unique reference for correlating replies (UUID v4 or monotonic binary). Required for `:call`, `:reply`, `:error`.
- `route` (atom or binary): Identifies the RPC entry.
- `meta` (map): Arbitrary metadata propagated end-to-end (e.g., tracing ids).
- `timeout_ms` (non_neg_integer): Requested timeout in milliseconds. Optional.

## Message Types

### `:call`
Used for request/response interactions. Payload:
```elixir
%{
  msg_id: binary(),
  route: atom() | binary(),
  args: term(),
  caller: peer_info(),
  timeout_ms: non_neg_integer() | nil,
  meta: map()
}
```
- Receiver MUST execute handler asynchronously and respond with either `:reply` or `:error` using the same `msg_id`.
- If handler exceeds `timeout_ms`, sender SHOULD emit `:error` with `:timeout`.

### `:cast`
Fire-and-forget invocation. Payload:
```elixir
%{
  route: atom() | binary(),
  args: term(),
  caller: peer_info(),
  meta: map()
}
```
- No reply expected. Receiver SHOULD ack internally; optional `:notify` may be emitted for confirmation.

### `:reply`
Successful response to a `:call`:
```elixir
%{
  msg_id: binary(),
  result: term(),
  meta: map()
}
```
- MUST match a pending `msg_id`. Unexpected replies are logged and ignored.

### `:error`
Failure outcome for a `:call`. Payload:
```elixir
%{
  msg_id: binary(),
  reason: atom(),
  detail: term(),
  meta: map()
}
```
- `reason` examples: `:timeout`, `:bad_route`, `:unauthorized`, `:internal`.
- Sender may include structured error data; consumers SHOULD guard decode.

### `:notify`
Optional informational message (e.g., server->client events, cast acknowledgements). Payload may contain:
```elixir
%{
  route: atom() | binary(),
  event: atom(),
  data: term(),
  meta: map()
}
```

### `:discover`
Allows a peer to request available actions. Payload:
```elixir
%{
  msg_id: binary(),
  scope: :all | :calls | :casts,
  meta: map()
}
```
- Receiver responds with `:discover_reply`.

### `:discover_reply`
```
%{
  msg_id: binary(),
  entries: [
    %{
      route: atom() | binary(),
      kind: :call | :cast,
      doc: binary() | nil,
      timeout_ms: non_neg_integer() | nil,
      meta: map()
    }, ...
  ],
  meta: map()
}
```

### `:heartbeat`
Periodic keepalive to detect stale connections. Payload:
```elixir
%{
  ts: non_neg_integer(),
  meta: map()
}
```
- Peers MAY piggyback latency metrics in `meta`.

## Peer Info Structure
`peer_info()` is a map with fields such as:
```elixir
%{
  id: binary(),
  role: :client | :server | :peer,
  version: Version.t() | nil,
  node: atom() | nil,
  capabilities: [atom()]
}
```
- Populated by each side during handshake and cached for future frames.

## Error Handling
- Malformed frames (decode errors, missing required keys) MUST trigger `:error` with `:invalid_frame` when possible; otherwise close the socket.
- Timeouts: When a `:call` exceeds its timeout without reply, the caller emits `:error` and cleans up local state. The callee SHOULD still finish work but MUST drop late replies.
- Retries: Left to higher-level policy; protocol remains stateless regarding retry semantics.

## Flow Control & Concurrency
- Each peer maintains a registry of in-flight calls keyed by `msg_id`. Registry enforces maximum outstanding call count; exceeding limit SHOULD reject new calls with `:error, :over_capacity`.
- Handlers run in supervised asynchronous tasks; the WebSocket process only manages encode/decode and dispatch.
- Optional `:throttle` notifications MAY be introduced in future versions; reserved payload key `:throttle`.

## Authentication & Security

### Authentication During Handshake

RpcEx supports pluggable authentication that occurs during the WebSocket handshake, before any RPC messages are exchanged. This ensures that only authenticated clients can establish connections.

#### Server-Side Authentication

Servers can configure authentication by implementing the `RpcEx.Server.Auth` behaviour and passing it as the `:auth` option:

```elixir
defmodule MyApp.TokenAuth do
  @behaviour RpcEx.Server.Auth

  @impl true
  def authenticate(credentials, _opts) do
    case validate_token(credentials) do
      {:ok, user} ->
        # Return context that will be available to all handlers
        {:ok, %{user_id: user.id, roles: user.roles, authenticated: true}}

      {:error, reason} ->
        {:error, :invalid_token, reason}
    end
  end
end

# Configure server with auth
{RpcEx.Server, router: MyRouter, port: 4000, auth: {MyApp.TokenAuth, []}}
```

The `authenticate/2` callback receives:
- `credentials`: The value from `meta["auth"]` in the `:hello` frame
- `opts`: Options passed when configuring the auth module

It must return:
- `{:ok, auth_context}` - A map that will be merged into the handler `context`
- `{:error, reason}` or `{:error, reason, detail}` - Authentication failure

#### Client-Side Credentials

Clients pass credentials in the `:hello` frame's `meta` field under the `"auth"` key:

```elixir
{:ok, client} = RpcEx.Client.start_link(
  url: "ws://localhost:4000",
  handshake: [
    meta: %{
      "auth" => %{
        "token" => "jwt-token-here"
      }
    }
  ]
)
```

The credentials structure is flexible and application-defined. Common patterns:
- Token-based: `%{"token" => "..."}`
- Username/password: `%{"username" => "...", "password" => "..."}`
- API keys: `%{"api_key" => "..."}`
- Custom challenges: `%{"challenge_response" => "..."}`

#### Authentication Flow

1. Client sends `:hello` frame with `meta: %{"auth" => credentials}`
2. Server extracts credentials from `meta["auth"]`
3. Server calls `AuthModule.authenticate(credentials, opts)`
4. On success:
   - Server merges auth context into connection context
   - Server sends `:welcome` frame
   - Connection proceeds normally
5. On failure:
   - Server sends `{:close, :authentication_failed, reason}` frame
   - Connection is terminated
   - Client receives disconnection event

#### Handler Access to Auth Context

Once authenticated, handlers receive the auth context merged into their `context` binding:

```elixir
call :get_profile do
  # Auth context is available
  user_id = context.user_id
  roles = context.roles

  if :admin in roles do
    {:ok, get_admin_profile(user_id)}
  else
    {:ok, get_user_profile(user_id)}
  end
end
```

### General Security Considerations

- **Transport Security**: Sensitive data in payloads must rely on transport security (TLS/WSS). Use `wss://` URLs in production.
- **Route Validation**: Both peers MUST validate routes against registered handlers to avoid arbitrary execution.
- **Credential Storage**: Never log or store credentials in plaintext. Authentication modules should use secure comparison functions.
- **Token Rotation**: For long-lived connections, consider implementing token refresh via a dedicated RPC route.
- **Rate Limiting**: Applications should implement rate limiting in middleware to prevent abuse.
- **Input Validation**: Always validate and sanitize `args` in handlers before processing.

## Versioning
- Protocol version currently `1`. Negotiation occurs in `:hello`/`:welcome`.
- Future incompatible changes increment `protocol_version`; peers MUST close connection if version unsupported.
- Message `version` allows evolving individual message schemas within the same session.

## Extensibility Guidelines
- All payload maps SHOULD be tolerant of unknown keys.
- Reserved keys: `msg_id`, `route`, `args`, `result`, `reason`, `detail`, `meta`, `timeout_ms`, `caller`.
- New message types should be documented and gated behind capability flags exchanged during handshake.

## Reference Implementation Hooks
- `RpcEx.Protocol.Handshake` handles `:hello`/`:welcome` exchange.
- `RpcEx.Protocol.Frame` provides encode/decode utilities, enforcing compression defaults.
- `RpcEx.Router` supplies compile-time metadata for discovery responses.
- `RpcEx.Transport` abstracts client/server WebSocket details to support alternative adapters in future.

## Testing Recommendations
- Property tests for encode/decode (`RpcEx.Codec`).
- Integration tests verifying negotiation, bidirectional calls, error propagation, discovery, and heartbeat behaviour using Bandit + Mint in supervision trees.
- Fuzzing or mutation testing for resilience against malformed frames.
