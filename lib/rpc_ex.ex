defmodule RpcEx do
  @moduledoc """
  RPC-Ex is a bidirectional RPC-over-WebSocket toolkit for Elixir.

  The library is transport-agnostic, encoding messages as ETF binaries and
  exposing a declarative router DSL for defining `call` and `cast` handlers on
  both client and server peers.
  """

  @typedoc "Identifier used to match request/response pairs."
  @type message_id :: binary()

  @typedoc "Route names accepted by the router DSL."
  @type route :: atom() | String.t()

  @typedoc "Arbitrary RPC payload."
  @type payload :: term()

  @typedoc "Metadata propagated alongside RPC calls."
  @type metadata :: map()

  @typedoc "Options accepted by RPC operations."
  @type options :: keyword()
end
