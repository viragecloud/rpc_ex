# Run with: mix run benchmarks/codec_bench.exs

Code.require_file("support/fixtures.ex", __DIR__)

alias RpcEx.Codec
alias Benchmarks.Fixtures

# Prepare payloads
payloads = Fixtures.payloads()

# Pre-encode payloads for decode benchmarks
{:ok, tiny_bin} = Codec.encode(payloads.tiny)
{:ok, small_bin} = Codec.encode(payloads.small)
{:ok, medium_bin} = Codec.encode(payloads.medium)
{:ok, large_bin} = Codec.encode(payloads.large)
{:ok, xlarge_bin} = Codec.encode(payloads.xlarge)

encoded_payloads = %{
  tiny: tiny_bin,
  small: small_bin,
  medium: medium_bin,
  large: large_bin,
  xlarge: xlarge_bin
}

IO.puts("\n=== RpcEx Codec Benchmarks ===\n")
IO.puts("Benchmarking ETF encoding/decoding performance with various payload sizes.\n")

Benchee.run(
  %{
    # Encoding benchmarks
    "encode tiny (~50B)" => fn -> Codec.encode(payloads.tiny) end,
    "encode small (~500B)" => fn -> Codec.encode(payloads.small) end,
    "encode medium (~5KB)" => fn -> Codec.encode(payloads.medium) end,
    "encode large (~50KB)" => fn -> Codec.encode(payloads.large) end,
    "encode xlarge (~500KB)" => fn -> Codec.encode(payloads.xlarge) end,

    # Decoding benchmarks
    "decode tiny (~50B)" => fn -> Codec.decode(encoded_payloads.tiny) end,
    "decode small (~500B)" => fn -> Codec.decode(encoded_payloads.small) end,
    "decode medium (~5KB)" => fn -> Codec.decode(encoded_payloads.medium) end,
    "decode large (~50KB)" => fn -> Codec.decode(encoded_payloads.large) end,
    "decode xlarge (~500KB)" => fn -> Codec.decode(encoded_payloads.xlarge) end,

    # Round-trip benchmarks
    "roundtrip tiny" => fn ->
      {:ok, binary} = Codec.encode(payloads.tiny)
      Codec.decode(binary)
    end,
    "roundtrip small" => fn ->
      {:ok, binary} = Codec.encode(payloads.small)
      Codec.decode(binary)
    end,
    "roundtrip medium" => fn ->
      {:ok, binary} = Codec.encode(payloads.medium)
      Codec.decode(binary)
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

IO.puts("\n=== Compression Level Comparison ===\n")
IO.puts("Testing different compression levels with medium payload (~5KB).\n")

# Compare compression levels
payload = payloads.medium

Benchee.run(
  %{
    "compression: 0 (none)" => fn -> Codec.encode(payload, compressed: 0) end,
    "compression: 1 (fast)" => fn -> Codec.encode(payload, compressed: 1) end,
    "compression: 6 (default)" => fn -> Codec.encode(payload, compressed: 6) end,
    "compression: 9 (best)" => fn -> Codec.encode(payload, compressed: 9) end
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

# Display compression ratios
IO.puts("\n=== Compression Ratios ===\n")

for {name, payload} <- payloads do
  {:ok, uncompressed} = Codec.encode(payload, compressed: 0)
  {:ok, compressed_6} = Codec.encode(payload, compressed: 6)
  {:ok, compressed_9} = Codec.encode(payload, compressed: 9)

  ratio_6 = Float.round((1 - byte_size(compressed_6) / byte_size(uncompressed)) * 100, 1)
  ratio_9 = Float.round((1 - byte_size(compressed_9) / byte_size(uncompressed)) * 100, 1)

  IO.puts("#{String.pad_trailing(to_string(name), 10)}: " <>
          "#{String.pad_leading(to_string(byte_size(uncompressed)), 8)} bytes uncompressed, " <>
          "#{String.pad_leading(to_string(byte_size(compressed_6)), 8)} bytes (lvl 6, #{ratio_6}% reduction), " <>
          "#{String.pad_leading(to_string(byte_size(compressed_9)), 8)} bytes (lvl 9, #{ratio_9}% reduction)")
end

IO.puts("\n✓ Codec benchmarks complete!\n")
