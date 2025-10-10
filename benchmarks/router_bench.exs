# Run with: mix run benchmarks/router_bench.exs

Code.require_file("support/fixtures.ex", __DIR__)

alias RpcEx.Router.Executor
alias Benchmarks.Fixtures

IO.puts("\n=== RpcEx Router Benchmarks ===\n")
IO.puts("Benchmarking route dispatch and execution performance.\n")

# Setup routers
simple_router = Fixtures.simple_router()
router_with_middleware = Fixtures.router_with_middleware()

# Test args
tiny_args = Fixtures.tiny_payload()
small_args = Fixtures.small_payload()
medium_args = Fixtures.medium_payload()

IO.puts("=== Handler Execution Overhead ===\n")
IO.puts("Measuring the cost of dispatching to different handler types.\n")

Benchee.run(
  %{
    "noop handler" => fn ->
      Executor.dispatch(simple_router, :call, :noop, %{})
    end,
    "echo handler (tiny)" => fn ->
      Executor.dispatch(simple_router, :call, :echo, tiny_args)
    end,
    "echo handler (small)" => fn ->
      Executor.dispatch(simple_router, :call, :echo, small_args)
    end,
    "echo handler (medium)" => fn ->
      Executor.dispatch(simple_router, :call, :echo, medium_args)
    end,
    "compute handler" => fn ->
      Executor.dispatch(simple_router, :call, :compute, %{})
    end,
    "cast (notify)" => fn ->
      Executor.dispatch(simple_router, :cast, :notify, tiny_args)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  formatters: [
    {Benchee.Formatters.Console,
     extended_statistics: true}
  ],
  print: [
    fast_warning: false
  ]
)

IO.puts("\n=== Middleware Overhead ===\n")
IO.puts("Comparing dispatch with and without middleware.\n")

Benchee.run(
  %{
    "no middleware" => fn ->
      Executor.dispatch(simple_router, :call, :echo, tiny_args)
    end,
    "with middleware" => fn ->
      Executor.dispatch(router_with_middleware, :call, :echo, tiny_args)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  formatters: [
    {Benchee.Formatters.Console,
     extended_statistics: true}
  ],
  print: [
    fast_warning: false
  ]
)

IO.puts("\n=== Route Lookup Performance ===\n")
IO.puts("Measuring route lookup time with different numbers of registered routes.\n")

# Create routers with different numbers of routes
router_10 = Fixtures.router_with_many_routes(10)
router_50 = Fixtures.router_with_many_routes(50)
router_100 = Fixtures.router_with_many_routes(100)

Benchee.run(
  %{
    "10 routes (first)" => fn ->
      Executor.dispatch(router_10, :call, :route_1, %{})
    end,
    "10 routes (middle)" => fn ->
      Executor.dispatch(router_10, :call, :route_5, %{})
    end,
    "10 routes (last)" => fn ->
      Executor.dispatch(router_10, :call, :route_10, %{})
    end,
    "50 routes (first)" => fn ->
      Executor.dispatch(router_50, :call, :route_1, %{})
    end,
    "50 routes (middle)" => fn ->
      Executor.dispatch(router_50, :call, :route_25, %{})
    end,
    "50 routes (last)" => fn ->
      Executor.dispatch(router_50, :call, :route_50, %{})
    end,
    "100 routes (first)" => fn ->
      Executor.dispatch(router_100, :call, :route_1, %{})
    end,
    "100 routes (middle)" => fn ->
      Executor.dispatch(router_100, :call, :route_50, %{})
    end,
    "100 routes (last)" => fn ->
      Executor.dispatch(router_100, :call, :route_100, %{})
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  formatters: [
    {Benchee.Formatters.Console,
     extended_statistics: true}
  ],
  print: [
    fast_warning: false
  ]
)

IO.puts("\n=== Context Handling ===\n")
IO.puts("Measuring the cost of context propagation and manipulation.\n")

small_context = %{user_id: 123}
large_context = %{
  user_id: 123,
  session_id: "abc123",
  roles: [:user, :admin],
  permissions: [:read, :write, :delete],
  metadata: %{
    login_time: 1234567890,
    ip_address: "192.168.1.1",
    user_agent: "RpcEx/1.0"
  }
}

Benchee.run(
  %{
    "no context" => fn ->
      Executor.dispatch(simple_router, :call, :noop, %{})
    end,
    "small context" => fn ->
      Executor.dispatch(simple_router, :call, :noop, %{}, small_context)
    end,
    "large context" => fn ->
      Executor.dispatch(simple_router, :call, :noop, %{}, large_context)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  formatters: [
    {Benchee.Formatters.Console,
     extended_statistics: true}
  ],
  print: [
    fast_warning: false
  ]
)

IO.puts("\n✓ Router benchmarks complete!\n")
