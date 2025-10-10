defmodule RpcEx do
  @moduledoc """
  RPC-Ex is a bidirectional RPC-over-WebSocket toolkit for Elixir.

  The library uses ETF (External Term Format) for message encoding and provides
  a declarative router DSL for defining `call` (request/response) and `cast`
  (fire-and-forget) handlers on both client and server peers.

  ## Features

  - **Bidirectional RPC**: Both client and server can initiate calls
  - **High Concurrency**: Non-blocking execution with supervised tasks
  - **Type-Safe Protocol**: ETF encoding with compression support
  - **Route Discovery**: Introspect available routes at runtime
  - **Middleware Support**: Composable middleware chain
  - **Auto-Reconnection**: Built-in reconnection with exponential backoff

  ## Quick Example

      # Define a router
      defmodule MyApp.Router do
        use RpcEx.Router

        call :add do
          {:ok, args[:a] + args[:b]}
        end
      end

      # Start server
      {:ok, _server} = RpcEx.Server.start_link(
        router: MyApp.Router,
        port: 4000
      )

      # Connect client
      {:ok, client} = RpcEx.Client.start_link(
        url: "ws://localhost:4000"
      )

      # Make a call
      {:ok, result, _meta} = RpcEx.Client.call(client, :add, args: %{a: 1, b: 2})
      # result => 3

  ## Architecture

  RpcEx is organized into several key modules:

  - `RpcEx.Server` - WebSocket server built on Bandit
  - `RpcEx.Client` - WebSocket client using Mint
  - `RpcEx.Router` - DSL for defining RPC routes
  - `RpcEx.Protocol.Frame` - Message framing and encoding
  - `RpcEx.Peer` - Handle for bidirectional calls from handlers

  See the README and individual module documentation for detailed usage.
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
