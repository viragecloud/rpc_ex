# RPC-Ex Project Plan

## Vision
Deliver a production-ready, bidirectional RPC-over-WebSocket library for Elixir that uses ETF-encoded binary frames, supports modern tooling (Bandit, Mint), and enables high-throughput, non-blocking call and cast semantics between peers with strong observability, configurability, and developer ergonomics.

## Guiding Principles
- Prefer OTP primitives and supervision for resilience; never block the WebSocket process.
- Encode all payloads with `:erlang.term_to_binary/2` (compression enabled by default) and decode with matching safeguards.
- Maintain discoverability (`describe` API, reflection endpoints) and a small, declarative surface for routing.
- Enforce quality gates: exhaustive tests, credo clean, dialyzer-ready typespecs, moduledocs for public APIs.
- Design for extensibility: transport layer pluggable, option validation centralized, telemetry hooks everywhere.

## Work Breakdown Structure

### Phase 0 — Foundations
1. **Research & Decisions**
   - Confirm target Elixir/OTP versions and CI matrix.
   - Select dependencies: `bandit`, `mint_web_socket`, `nimble_options`, `telemetry`, `stream_data`, `ex_doc`, optional `dialyxir`.
   - Define binary framing: handshake, message envelope (message type, id/ref, payload, headers, compression flag).
2. **Repository Setup**
   - Configure `mix format`, `mix credo`, `.tool-versions`/`.formatter.exs`.
   - Add CI scaffolding (GitHub Actions or alternative).
   - Establish `docs/`, `examples/`, `test/support/` directories.

### Phase 1 — Protocol & Codec
1. **Message Schema**
   - Write `docs/protocol.md` capturing handshake, messages (`call`, `cast`, `reply`, `error`, `notify`, `discover`).
   - Define serialization module `RpcEx.Protocol.Frame`.
2. **Codec Implementation**
   - Implement `RpcEx.Codec` for ETF encode/decode with safe options (`compressed`, `minor_version => 1`).
   - Property tests for round-tripping, oversized payload guardrails, and compression toggles.

### Phase 2 — Core Runtime
1. **Connection Supervision**
   - Server supervisor: Bandit handler process, connection registry, Task supervisors for call execution.
   - Client supervisor: Mint connection manager, heartbeat Task, pending call tracker using `Registry`/`ETS`.
2. **Routing DSL**
   - `RpcEx.Router` macro to declare `call` and `cast` handlers; compile-time metadata for discovery.
   - Support middleware stack (before/after hooks) and shared context injection.
3. **Action Discovery**
   - Build `RpcEx.Reflection` to expose defined routes, metadata (input spec, call/cast, options).
   - Provide optional discovery RPC command (`discover/0`) returning action list.

### Phase 3 — Client & Server APIs
1. **Server**
   - `RpcEx.Server` to spin up Bandit endpoint with router, handshake, and connection lifecycle management.
   - Pluggable authentication hook, backpressure (queue limits), per-call timeout defaults.
2. **Client**
   - `RpcEx.Client` with `connect/1`, `call/4`, `cast/4`, `stream/4` (optional), per-call options (timeout, retries, metadata).
   - Handle reconnects, exponential backoff, and detection of stale references.
3. **Bidirectional Support**
   - Enable server-initiated RPC to client once session established via same routing DSL on client side.
   - Mirror router/handler definitions for client handlers.

### Phase 4 — Observability & Safeguards
1. **Telemetry**
   - Emit events for connection lifecycle, call start/stop/error, retries, queue drops.
   - Provide metrics instrumentation examples for Prometheus/TelemetryMetrics.
2. **Timeouts & Circuit Breakers**
   - Configurable per-call timeout and default.
   - Optional retry strategy with jitter; circuit breaker behaviour for repeated failures.
3. **Logging & Tracing**
   - Structured logging metadata (request id, route, peer info).
   - Integrate with `:logger`, allow custom log handlers.

### Phase 5 — Tooling, Docs, Examples
1. **Testing**
   - Build integration tests spinning up Bandit server in test environment and exercise client.
   - Use `ExUnit.CaseTemplate` for shared fixtures; asynchronous tests by default.
   - Add negative tests (timeouts, malformed frames, disconnect recovery).
2. **Examples**
   - Provide `examples/ping_pong/` with simple call/cast interplay.
   - Include instructions for running example.
3. **Documentation**
   - Write comprehensive guides (`docs/getting_started.md`, `docs/architecture.md`).
   - Generate ExDoc with module docs and type specs.

### Phase 6 — Release Readiness
1. **Performance Validation**
   - Benchmarks using `benchee` or `broadway_bench` scenario for throughput.
   - Document backpressure tuning guidelines.
2. **Packaging**
   - Hex package metadata, changelog, semantic versioning rules.
   - Release checklist (tagging, docs generation, publishing).

## Timeline & Milestones (Indicative)
- Weeks 1-2: Phase 0, Phase 1 completion.
- Weeks 3-4: Phase 2 with initial router DSL.
- Weeks 5-6: Client & Server API integration, bidirectional flows.
- Week 7: Observability, resilience features, telemetry.
- Week 8: Testing hardening, docs/examples, release prep.

## Risk & Mitigation
- **WebSocket Backpressure**: Mitigate via message queue limits and supervised Task pools.
- **Protocol Evolution**: Version messages; include compatibility negotiation in handshake.
- **Timeout Tuning**: Expose runtime overrides and sensible defaults with telemetry for insight.
- **Tooling Drift**: Lock dependency versions, CI ensures `mix credo --strict` and tests run on PRs.

## Next Immediate Actions
1. Implement Phase 0 tasks (formatter, credo config, dependency declaration, initial docs).
2. Draft detailed protocol specification (`docs/protocol.md`).
3. Scaffold router DSL and codec modules with failing tests to drive development.
