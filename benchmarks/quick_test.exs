# Quick test to verify benchmarks work
# Run with: mix run benchmarks/quick_test.exs

Code.require_file("support/fixtures.ex", __DIR__)

alias RpcEx.Codec
alias RpcEx.Router.Executor
alias Benchmarks.Fixtures

IO.puts("\n=== Quick Benchmark Verification ===\n")

# Test codec
payloads = Fixtures.payloads()
IO.puts("✓ Fixtures loaded")

{:ok, _binary} = Codec.encode(payloads.tiny)
IO.puts("✓ Codec encode works")

# Test router
router = Fixtures.simple_router()
{:ok, _result, _ctx} = Executor.dispatch(router, :call, :noop, %{})
IO.puts("✓ Router dispatch works")

IO.puts("\n=== Running Quick Codec Benchmark ===\n")

Benchee.run(
  %{
    "encode tiny" => fn -> Codec.encode(payloads.tiny) end,
    "encode small" => fn -> Codec.encode(payloads.small) end
  },
  time: 0.5,
  warmup: 0.1,
  print: [fast_warning: false]
)

IO.puts("\n=== Running Quick Router Benchmark ===\n")

Benchee.run(
  %{
    "noop handler" => fn -> Executor.dispatch(router, :call, :noop, %{}) end,
    "echo handler" => fn -> Executor.dispatch(router, :call, :echo, payloads.tiny) end
  },
  time: 0.5,
  warmup: 0.1,
  print: [fast_warning: false]
)

IO.puts("\n✓ All benchmarks working correctly!\n")
IO.puts("Run full benchmarks with:")
IO.puts("  mix run benchmarks/codec_bench.exs    (takes ~2-3 minutes)")
IO.puts("  mix run benchmarks/router_bench.exs   (takes ~3-4 minutes)\n")
