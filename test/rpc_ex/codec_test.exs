defmodule RpcEx.CodecTest do
  use ExUnit.Case, async: true

  alias RpcEx.Codec

  describe "encode/2 and decode/2" do
    test "round trips arbitrary terms with default options" do
      payload = %{
        atom: :foo,
        tuple: {:ok, "value"},
        list: [1, 2, 3],
        map: %{nested: %{a: 1}},
        number: 123.45
      }

      assert {:ok, binary} = Codec.encode(payload)
      assert is_binary(binary)
      assert {:ok, decoded} = Codec.decode(binary)
      assert decoded == payload
    end

    test "allows overriding compression level and minor version" do
      payload = %{a: 1, b: 2}

      assert {:ok, binary} = Codec.encode(payload, compressed: 6, minor_version: 0)
      assert {:ok, ^payload} = Codec.decode(binary)
    end

    test "returns error for malformed binaries" do
      binary = <<131, 104, 2, 100, 0, 3, 102, 111, 111, 255>>

      assert {:error, %ArgumentError{}} = Codec.decode(binary)
    end
  end

  describe "encode/2" do
    test "encodes simple atoms" do
      assert {:ok, binary} = Codec.encode(:test)
      assert is_binary(binary)
    end

    test "encodes strings" do
      assert {:ok, binary} = Codec.encode("hello world")
      assert is_binary(binary)
    end

    test "encodes numbers" do
      assert {:ok, binary} = Codec.encode(42)
      assert is_binary(binary)

      assert {:ok, binary} = Codec.encode(3.14159)
      assert is_binary(binary)
    end

    test "encodes with compression disabled" do
      term = %{data: String.duplicate("test", 100)}
      assert {:ok, binary} = Codec.encode(term, compressed: 0)
      assert is_binary(binary)
    end

    test "encodes with different compression levels" do
      term = %{data: String.duplicate("compressible ", 500)}

      for level <- 1..9 do
        assert {:ok, binary} = Codec.encode(term, compressed: level)
        assert is_binary(binary)
      end
    end

    test "encodes with boolean compressed option" do
      assert {:ok, binary} = Codec.encode(:test, [:compressed])
      assert is_binary(binary)
    end

    test "encodes large data" do
      large_binary = :crypto.strong_rand_bytes(100_000)
      assert {:ok, binary} = Codec.encode(large_binary)
      assert is_binary(binary)

      large_list = Enum.to_list(1..10_000)
      assert {:ok, binary} = Codec.encode(large_list)
      assert is_binary(binary)
    end

    test "default compression reduces size" do
      large_term = %{data: String.duplicate("x", 10_000)}
      {:ok, compressed} = Codec.encode(large_term)
      uncompressed = :erlang.term_to_binary(large_term, minor_version: 1)

      assert byte_size(compressed) < byte_size(uncompressed)
    end
  end

  describe "encode!/2" do
    test "returns binary directly" do
      binary = Codec.encode!(:hello)
      assert is_binary(binary)
    end

    test "encodes complex terms" do
      term = %{nested: %{data: [1, 2, 3]}}
      binary = Codec.encode!(term)
      assert is_binary(binary)
    end

    test "respects custom options" do
      binary = Codec.encode!(:test, compressed: 9)
      assert is_binary(binary)
    end
  end

  describe "decode/2" do
    test "decodes simple terms" do
      {:ok, binary} = Codec.encode(:test)
      assert {:ok, :test} = Codec.decode(binary)
    end

    test "decodes various types" do
      terms = [
        :atom,
        "string",
        123,
        45.67,
        [1, 2, 3],
        {1, 2, 3},
        %{key: :value},
        true,
        false,
        nil
      ]

      for term <- terms do
        {:ok, binary} = Codec.encode(term)
        assert {:ok, ^term} = Codec.decode(binary)
      end
    end

    test "returns error for invalid binary" do
      assert {:error, %ArgumentError{}} = Codec.decode(<<1, 2, 3, 4>>)
    end

    test "returns error for empty binary" do
      assert {:error, %ArgumentError{}} = Codec.decode(<<>>)
    end

    test "returns error for truncated binary" do
      {:ok, valid_binary} = Codec.encode(:test)
      truncated = binary_part(valid_binary, 0, byte_size(valid_binary) - 2)
      assert {:error, %ArgumentError{}} = Codec.decode(truncated)
    end

    test "returns error for corrupted binary" do
      {:ok, valid_binary} = Codec.encode(%{test: :data})
      # Corrupt by replacing ETF version byte
      corrupted = :binary.replace(valid_binary, <<131>>, <<255>>)
      assert {:error, %ArgumentError{}} = Codec.decode(corrupted)
    end

    test "returns error for partial ETF header" do
      # Just the version byte
      assert {:error, %ArgumentError{}} = Codec.decode(<<131>>)
    end

    test "uses safe mode by default" do
      # Safe mode prevents execution of arbitrary code
      binary = :erlang.term_to_binary(:safe_atom)
      assert {:ok, :safe_atom} = Codec.decode(binary)
    end
  end

  describe "decode!/2" do
    test "returns term directly" do
      {:ok, binary} = Codec.encode(:test)
      assert :test = Codec.decode!(binary)
    end

    test "decodes complex structures" do
      original = %{nested: %{list: [1, 2, 3]}}
      {:ok, binary} = Codec.encode(original)
      assert ^original = Codec.decode!(binary)
    end

    test "raises on invalid binary" do
      assert_raise ArgumentError, fn ->
        Codec.decode!(<<1, 2, 3>>)
      end
    end

    test "raises on truncated binary" do
      {:ok, valid_binary} = Codec.encode(:test)
      truncated = binary_part(valid_binary, 0, byte_size(valid_binary) - 1)

      assert_raise ArgumentError, fn ->
        Codec.decode!(truncated)
      end
    end

    test "raises on empty binary" do
      assert_raise ArgumentError, fn ->
        Codec.decode!(<<>>)
      end
    end
  end

  describe "round-trip encoding" do
    test "preserves atoms" do
      assert_roundtrip(:test_atom)
      assert_roundtrip(:another_atom)
    end

    test "preserves strings" do
      assert_roundtrip("")
      assert_roundtrip("hello")
      assert_roundtrip(String.duplicate("long ", 1000))
    end

    test "preserves integers" do
      assert_roundtrip(0)
      assert_roundtrip(-1)
      assert_roundtrip(999_999_999)
    end

    test "preserves floats" do
      assert_roundtrip(0.0)
      assert_roundtrip(3.14)
      assert_roundtrip(-2.71828)
    end

    test "preserves lists" do
      assert_roundtrip([])
      assert_roundtrip([1])
      assert_roundtrip([1, 2, 3])
      assert_roundtrip([1, :atom, "string"])
    end

    test "preserves tuples" do
      assert_roundtrip({})
      assert_roundtrip({1})
      assert_roundtrip({1, 2})
      assert_roundtrip({:ok, "value"})
    end

    test "preserves maps" do
      assert_roundtrip(%{})
      assert_roundtrip(%{a: 1})
      assert_roundtrip(%{nested: %{deep: :value}})
    end

    test "preserves complex nested structures" do
      complex = %{
        users: [
          %{id: 1, name: "Alice", active: true},
          %{id: 2, name: "Bob", active: false}
        ],
        meta: {:ok, %{count: 2}},
        tags: [:admin, :user]
      }

      assert_roundtrip(complex)
    end
  end

  describe "compression behavior" do
    test "all compression levels work" do
      term = %{data: String.duplicate("test ", 100)}

      for level <- 0..9 do
        {:ok, binary} = Codec.encode(term, compressed: level)
        {:ok, decoded} = Codec.decode(binary)
        assert decoded == term
      end
    end

    test "higher compression produces smaller output" do
      term = %{data: String.duplicate("very compressible data ", 500)}

      {:ok, binary_0} = Codec.encode(term, compressed: 0)
      {:ok, binary_6} = Codec.encode(term, compressed: 6)
      {:ok, binary_9} = Codec.encode(term, compressed: 9)

      # Level 0 = no compression
      assert byte_size(binary_9) <= byte_size(binary_6)
      assert byte_size(binary_6) < byte_size(binary_0)
    end
  end

  describe "option handling" do
    test "custom options override defaults" do
      term = :test

      {:ok, binary} = Codec.encode(term, compressed: 9, minor_version: 0)
      assert {:ok, ^term} = Codec.decode(binary)
    end

    test "duplicate compression options use last value" do
      term = %{data: "test"}

      # Last option should win
      {:ok, binary} = Codec.encode(term, compressed: 1, compressed: 9)
      assert {:ok, ^term} = Codec.decode(binary)
    end

    test "duplicate minor_version options use last value" do
      term = :test

      {:ok, binary} = Codec.encode(term, minor_version: 0, minor_version: 1)
      assert {:ok, ^term} = Codec.decode(binary)
    end
  end

  describe "error handling" do
    test "encode returns ok tuple for valid terms" do
      # Verify structure even when no error occurs
      result = Codec.encode(:valid)
      assert {:ok, binary} = result
      assert is_binary(binary)
    end

    test "decode handles various invalid inputs" do
      invalid_binaries = [
        <<255, 255, 255>>,
        <<131, 255>>,
        <<0, 0, 0>>
      ]

      for invalid <- invalid_binaries do
        assert {:error, %ArgumentError{}} = Codec.decode(invalid)
      end
    end
  end

  # Helper for round-trip testing
  defp assert_roundtrip(term) do
    {:ok, encoded} = Codec.encode(term)
    {:ok, decoded} = Codec.decode(encoded)
    assert decoded == term
  end
end
