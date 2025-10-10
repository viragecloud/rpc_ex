# RpcEx Benchmarks

This directory contains performance benchmarks for RpcEx core components. These benchmarks help establish performance baselines and identify bottlenecks.

## Prerequisites

```bash
# Install dependencies
mix deps.get
```

## Running Benchmarks

### Quick Verification (< 10 seconds)

```bash
# Quick test to verify benchmarks work
mix run benchmarks/quick_test.exs
```

This runs a short version to verify everything is set up correctly.

### Full Benchmarks

**Note:** Full benchmarks take 2-5 minutes each to run with proper statistics.

```bash
# Codec performance (encoding/decoding/compression) - ~2-3 minutes
mix run benchmarks/codec_bench.exs

# Router dispatch and lookup performance - ~3-4 minutes
mix run benchmarks/router_bench.exs
```

### All Benchmarks

```bash
# Run all benchmarks sequentially (~5-7 minutes total)
mix run benchmarks/codec_bench.exs && mix run benchmarks/router_bench.exs
```

## Benchmark Suite Overview

### 1. Codec Benchmarks (`codec_bench.exs`)

Measures ETF encoding/decoding performance with various payload sizes and compression levels.

**What's measured:**
- Encoding throughput (term → binary)
- Decoding throughput (binary → term)
- Round-trip performance
- Compression level impact (0, 1, 6, 9)
- Compression ratios for different payload sizes

**Payload sizes:**
- **Tiny** (~50 bytes): Simple map with 3 keys
- **Small** (~500 bytes): Typical RPC response with nested maps
- **Medium** (~5KB): List of 50 user records
- **Large** (~50KB): Complex nested structure with 100 records
- **XLarge** (~500KB): 1000 records with binary data

**Key metrics:**
- Operations per second (higher is better)
- Average execution time (lower is better)
- Memory consumption per operation
- Compression ratio (bytes saved)

**Expected results:**
- Tiny/small payloads: 100K-500K ops/sec
- Medium payloads: 10K-50K ops/sec
- Large payloads: 1K-10K ops/sec
- Compression level 6 offers best speed/size tradeoff

### 2. Router Benchmarks (`router_bench.exs`)

Measures route dispatch, lookup, and execution performance.

**What's measured:**
- Handler execution overhead (noop, echo, compute)
- Middleware overhead (with vs without)
- Route lookup performance (10, 50, 100 routes)
- Context propagation cost

**Test scenarios:**

**Handler types:**
- `noop`: Minimal handler (measures dispatch overhead)
- `echo`: Simple args passthrough
- `compute`: Handler with computation (100 iterations)
- `cast`: Fire-and-forget invocation

**Middleware overhead:**
- Router with no middleware (baseline)
- Router with single tracing middleware
- Measures `before/5` and `after_handle/5` costs

**Route lookup:**
- Tests with 10, 50, and 100 registered routes
- Measures first, middle, and last route lookup
- Identifies O(n) vs O(1) performance characteristics

**Context handling:**
- No context (baseline)
- Small context (3 keys)
- Large context (nested maps, lists)

**Key metrics:**
- Dispatch latency in microseconds (μs)
- Throughput in operations per second
- Memory per dispatch
- Linear vs constant lookup time

**Expected results:**
- Noop handler: 200K-500K ops/sec
- Echo handler: 100K-300K ops/sec
- Middleware overhead: ~1-2 μs per middleware
- Route lookup: Linear scan O(n) - consider optimization if >100 routes

## Interpreting Results

### Throughput (Operations/Second)

Higher is better. Indicates how many operations can be performed per second.

```
100 K ops/s  = 10 μs per operation   (excellent)
10 K ops/s   = 100 μs per operation  (good)
1 K ops/s    = 1 ms per operation    (acceptable for large payloads)
```

### Latency Percentiles

- **p50 (median)**: Typical operation time
- **p95**: 95% of operations complete within this time
- **p99**: 99% of operations complete within this time

Watch for large gaps between p50 and p99 - indicates inconsistent performance.

### Memory Usage

Shows memory allocated per operation. Lower is better for scalability.

```
< 1 KB per op    = Excellent
1-10 KB per op   = Good
10-100 KB per op = Acceptable (watch for GC pressure)
> 100 KB per op  = Concerning (investigate allocations)
```

### Comparison Mode

Benchee shows relative performance:

```
Name                    ips        average  deviation  median    99th %
encode tiny (~50B)   487.23 K     2.05 μs   ±10.45%   2.00 μs   3.12 μs
encode small (~500B) 124.56 K     8.03 μs   ±12.20%   7.85 μs  11.24 μs

Comparison:
encode tiny (~50B)   487.23 K
encode small (~500B) 124.56 K - 3.91x slower +6.0 μs
```

This shows small payloads take ~4x longer than tiny payloads.

## Performance Baselines

### Quick Test Results (M4 MacBook Pro, 16GB RAM)

From `mix run benchmarks/quick_test.exs`:

**Codec Performance:**
- `encode tiny (~50B)`: 402K ops/s (2.49 μs)
- `encode small (~500B)`: 186K ops/s (5.37 μs) - 2.16x slower than tiny

**Router Performance:**
- `noop handler`: 22M ops/s (45 ns) - Pure dispatch overhead
- `echo handler`: 6.2M ops/s (161 ns) - 3.56x slower than noop

These numbers represent excellent baseline performance for a modern Apple Silicon chip.

### Full Benchmark Baselines

These are approximate full benchmark results on a modern development machine:

### Codec Performance

| Payload Size | Encode    | Decode    | Round-trip |
|--------------|-----------|-----------|------------|
| Tiny (50B)   | 400K/s    | 500K/s    | 200K/s     |
| Small (500B) | 150K/s    | 200K/s    | 100K/s     |
| Medium (5KB) | 30K/s     | 40K/s     | 20K/s      |
| Large (50KB) | 4K/s      | 5K/s      | 2.5K/s     |
| XLarge (500KB)| 400/s    | 500/s     | 250/s      |

### Router Performance

| Operation        | Throughput | Latency |
|------------------|------------|---------|
| Noop handler     | 300K/s     | 3 μs    |
| Echo (tiny)      | 200K/s     | 5 μs    |
| Middleware       | +1-2 μs    | -       |
| Route lookup (100)| Same      | ~10 μs  |

## Optimization Strategies

Based on benchmark results, consider:

1. **Large payloads**: Use compression level 6 (default) for best speed/size tradeoff
2. **Many routes**: If >100 routes, consider route lookup optimization (map-based lookup)
3. **Middleware**: Keep middleware chains short; each adds 1-2 μs
4. **Context**: Keep context small; it's copied on each dispatch
5. **Batch operations**: For small payloads, consider batching to amortize overhead

## Hardware Impact

Benchmark results vary by hardware:

- **CPU speed**: Directly affects throughput
- **Memory bandwidth**: Impacts large payload handling
- **BEAM schedulers**: More cores = better concurrent performance

Run benchmarks on your target deployment hardware for accurate results.

## Adding New Benchmarks

To add new benchmarks:

1. Create `benchmarks/your_bench.exs`
2. Use `Benchee.run/2` with appropriate scenarios
3. Add fixtures to `benchmarks/support/fixtures.ex` if needed
4. Document in this README

Example structure:

```elixir
# benchmarks/your_bench.exs
Code.require_file("support/fixtures.ex", __DIR__)

IO.puts("\n=== Your Benchmark ===\n")

Benchee.run(
  %{
    "scenario 1" => fn -> your_code() end,
    "scenario 2" => fn -> other_code() end
  },
  time: 3,
  memory_time: 1,
  warmup: 1
)
```

## Continuous Benchmarking

Consider running benchmarks:

- Before/after performance optimizations
- On each major release
- When changing core algorithms
- To detect performance regressions

Save results for historical comparison:

```bash
# Save results to file
mix run benchmarks/codec_bench.exs | tee results/codec_$(date +%Y%m%d).txt
```

## Resources

- [Benchee Documentation](https://hexdocs.pm/benchee)
- [BEAM VM Performance](https://www.erlang.org/doc/efficiency_guide/introduction.html)
- [ETF Format Specification](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html)
