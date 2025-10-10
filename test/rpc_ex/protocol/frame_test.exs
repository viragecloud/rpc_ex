defmodule RpcEx.Protocol.FrameTest do
  use ExUnit.Case, async: true

  alias RpcEx.Protocol.Frame

  describe "new/3" do
    test "builds a frame struct with defaults" do
      payload = %{msg_id: "id", route: :echo}
      frame = Frame.new(:call, payload)

      assert %Frame{type: :call, version: 1, payload: ^payload} = frame
    end
  end

  describe "encode/2 and decode/2" do
    test "round trips valid frames" do
      payload = %{msg_id: "123", route: :echo, args: %{message: "hi"}}
      frame = Frame.new(:call, payload, version: 1)

      assert {:ok, binary} = Frame.encode(frame)
      assert {:ok, decoded} = Frame.decode(binary)
      assert decoded.type == :call
      assert decoded.version == 1
      assert decoded.payload == payload
    end

    test "detects invalid envelopes" do
      invalid_binary = :erlang.term_to_binary({:call, 0, %{}})

      assert {:error, :invalid_envelope} = Frame.decode(invalid_binary)
    end

    test "raises on decode! when invalid" do
      binary = :erlang.term_to_binary({:foo, "bad", []})

      assert_raise ArgumentError, fn -> Frame.decode!(binary) end
    end
  end
end
