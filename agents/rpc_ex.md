# Agent Guide: `rpc_ex`

## Overview
- Build a bidirectional RPC-over-WebSocket Elixir library that defaults to binary ETF payloads with compression and supports concurrent, backpressure-aware execution.
- Embrace Elixir OTP conventions and modern libraries (`Bandit`, `Mint.WebSocket`, `NimbleOptions`, `Telemetry`), keeping the surface small and ergonomic.
- Maintain compatibility with standard tooling: `mix format`, `mix test`, and `credo --strict` must pass with zero warnings.

## Non-Negotiables
- **Transport**: Use Mint WebSocket on the client, Bandit (or Cowboy fallback behind abstraction) on the server, ETF-encoded payloads, and opt-in compression.
- **Concurrency**: Never block WebSocket processes; off-load work to supervised Tasks or dedicated pools.
- **Robustness**: Provide configurable per-call timeouts, defensive supervision trees, retries/backoff hooks, and telemetry events.
- **Discoverability**: Expose introspection APIs for available calls/casts (both client and server).
- **Testing**: Comprehensive ExUnit suite with async coverage, integration tests for client/server flow, property tests for codec, and `mix credo` clean.

## Workstreams
1. **Protocol & Types**
   - Formalize ETF message schema (envelope, IDs, refs, payloads, error tuples).
   - Define feature capability negotiation and compression flags during handshake.
   - Document the wire contract in `docs/protocol.md`.
2. **Core Runtime**
   - Implement connection supervisors, registry for pending calls, and heartbeat/keepalive loops.
   - Provide router DSL (`use RpcEx.Router`) to declare `call` and `cast` handlers plus middleware pipeline.
   - Support server-side Bandit plug + handler and client connection module wrapping Mint.
3. **RPC API**
   - Expose functions: `RpcEx.Client.call/4`, `cast/4`, `stream/4` (if included), with per-invocation options.
   - Offer hook modules (behaviours) for authorization, tracing, and custom envelopes.
   - Implement discovery endpoints and reflection metadata.
4. **Observability & Resilience**
   - Emit telemetry events (`[:rpc_ex, :client|:server, ...]`).
   - Provide instrumentation helpers and metrics examples.
   - Add configurable retry strategies and circuit protection guard rails.
5. **Quality**
   - Build integration test harness that spins up Bandit server and Mint client within Sandbox.
   - Add property-based tests (e.g., with `stream_data`) for serializer/deserializer round-trips.
   - Ensure docs (`ExDoc`) and quick-start guides are present; check Credo and Dialyzer (if enabled).

## Definition of Done Checklists
- `mix test` (with async), `mix credo --strict`, and ideally `mix dialyzer` succeed.
- Protocol documented, public API documented via moduledocs/typespecs.
- Example project located under `examples/` demonstrates bidirectional RPC scenario.
- CHANGELOG updated and semantic versioning rules applied.

## Collaboration Notes
- Keep public API modules under `RpcEx.*`; internal helpers under `RpcEx.Internal.*`.
- Prefer `NimbleOptions` for validating user-facing options; keep options maps documented.
- Guard against race conditions by using `Registry` or `ETS` tables for in-flight calls with unique references.
- Before altering transport semantics, update protocol docs and consider migration strategy.

## Suggested Workflow for Agents
1. Sync with the latest plan (`docs/project_plan.md` once authored).
2. Work feature-by-feature; ensure tests exist/updated before moving on.
3. Use `mix format` after modifications; run `mix test` + `mix credo --strict` locally.
4. Capture follow-up tasks in TODO comments or `docs/backlog.md`.
5. End sessions with summary, verification results, and next recommended steps.
