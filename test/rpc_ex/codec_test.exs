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
end
