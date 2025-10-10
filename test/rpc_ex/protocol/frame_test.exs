defmodule RpcEx.Protocol.FrameTest do
  use ExUnit.Case, async: true

  alias RpcEx.Protocol.Frame

  describe "new/3" do
    test "builds a frame struct with defaults" do
      payload = %{msg_id: "id", route: :echo}
      frame = Frame.new(:call, payload)

      assert %Frame{type: :call, version: 1, payload: ^payload} = frame
    end

    test "accepts custom version" do
      frame = Frame.new(:call, %{}, version: 2)
      assert frame.version == 2
    end

    test "accepts all valid message types" do
      types = [
        :hello,
        :welcome,
        :close,
        :call,
        :cast,
        :reply,
        :error,
        :notify,
        :discover,
        :discover_reply,
        :heartbeat
      ]

      for type <- types do
        frame = Frame.new(type, %{})
        assert frame.type == type
        assert frame.version == 1
      end
    end

    test "accepts empty payload" do
      frame = Frame.new(:heartbeat, %{})
      assert frame.payload == %{}
    end

    test "accepts complex payload" do
      payload = %{
        msg_id: "123",
        route: :test,
        args: %{nested: %{data: [1, 2, 3]}},
        meta: %{request_id: "abc"}
      }

      frame = Frame.new(:call, payload)
      assert frame.payload == payload
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

  describe "encode/2" do
    test "encodes frame to binary" do
      frame = Frame.new(:hello, %{capabilities: [:calls]})
      assert {:ok, binary} = Frame.encode(frame)
      assert is_binary(binary)
    end

    test "encodes with custom options" do
      frame = Frame.new(:call, %{msg_id: "test"})
      assert {:ok, binary} = Frame.encode(frame, compressed: 9)
      assert is_binary(binary)
    end

    test "round trips all message types" do
      types = [
        :hello,
        :welcome,
        :close,
        :call,
        :cast,
        :reply,
        :error,
        :notify,
        :discover,
        :discover_reply,
        :heartbeat
      ]

      for type <- types do
        frame = Frame.new(type, %{data: :test})
        {:ok, binary} = Frame.encode(frame)
        {:ok, decoded} = Frame.decode(binary)
        assert decoded.type == type
        assert decoded.payload == %{data: :test}
      end
    end

    test "preserves complex payloads" do
      payload = %{
        users: [%{id: 1, name: "Alice"}],
        meta: %{timestamp: 123_456},
        nested: %{deep: %{value: :here}}
      }

      frame = Frame.new(:reply, payload)
      {:ok, binary} = Frame.encode(frame)
      {:ok, decoded} = Frame.decode(binary)

      assert decoded.payload == payload
    end
  end

  describe "encode!/2" do
    test "returns binary directly" do
      frame = Frame.new(:call, %{msg_id: "123"})
      binary = Frame.encode!(frame)
      assert is_binary(binary)
    end

    test "can be decoded" do
      frame = Frame.new(:cast, %{route: :test})
      binary = Frame.encode!(frame)
      {:ok, decoded} = Frame.decode(binary)

      assert decoded.type == :cast
      assert decoded.payload == %{route: :test}
    end

    test "respects custom options" do
      frame = Frame.new(:reply, %{result: :ok})
      binary = Frame.encode!(frame, compressed: 0)
      assert is_binary(binary)
    end
  end

  describe "decode/2" do
    test "decodes valid frame binary" do
      frame = Frame.new(:call, %{msg_id: "abc"})
      {:ok, binary} = Frame.encode(frame)

      assert {:ok, decoded} = Frame.decode(binary)
      assert decoded.type == :call
      assert decoded.version == 1
      assert decoded.payload == %{msg_id: "abc"}
    end

    test "returns error for invalid binary" do
      assert {:error, _} = Frame.decode(<<1, 2, 3, 4>>)
    end

    test "returns error for non-tuple term" do
      binary = :erlang.term_to_binary(:not_a_tuple)
      assert {:error, {:unexpected_term, :not_a_tuple}} = Frame.decode(binary)
    end

    test "returns error for wrong tuple size" do
      binary = :erlang.term_to_binary({:call, 1})
      assert {:error, {:unexpected_term, {:call, 1}}} = Frame.decode(binary)
    end

    test "returns error for invalid version (0)" do
      binary = :erlang.term_to_binary({:call, 0, %{}})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "returns error for negative version" do
      binary = :erlang.term_to_binary({:call, -1, %{}})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "returns error for non-integer version" do
      binary = :erlang.term_to_binary({:call, "1", %{}})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "returns error for non-atom type" do
      binary = :erlang.term_to_binary({"call", 1, %{}})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "returns error for non-map payload" do
      binary = :erlang.term_to_binary({:call, 1, "not a map"})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "returns error for list payload" do
      binary = :erlang.term_to_binary({:call, 1, []})
      assert {:error, :invalid_envelope} = Frame.decode(binary)
    end

    test "accepts valid version numbers" do
      for version <- [1, 2, 5, 10, 100] do
        binary = :erlang.term_to_binary({:call, version, %{}})
        assert {:ok, frame} = Frame.decode(binary)
        assert frame.version == version
      end
    end

    test "accepts empty payload map" do
      binary = :erlang.term_to_binary({:heartbeat, 1, %{}})
      assert {:ok, frame} = Frame.decode(binary)
      assert frame.payload == %{}
    end
  end

  describe "decode!/2" do
    test "returns frame directly on success" do
      frame = Frame.new(:reply, %{result: :ok})
      {:ok, binary} = Frame.encode(frame)

      decoded = Frame.decode!(binary)
      assert decoded.type == :reply
      assert decoded.payload == %{result: :ok}
    end

    test "raises ArgumentError on invalid binary" do
      assert_raise ArgumentError, ~r/invalid frame/, fn ->
        Frame.decode!(<<1, 2, 3>>)
      end
    end

    test "raises on invalid envelope" do
      binary = :erlang.term_to_binary({:call, 0, %{}})

      assert_raise ArgumentError, ~r/invalid frame.*:invalid_envelope/, fn ->
        Frame.decode!(binary)
      end
    end

    test "raises on non-tuple term" do
      binary = :erlang.term_to_binary(:atom)

      assert_raise ArgumentError, ~r/invalid frame/, fn ->
        Frame.decode!(binary)
      end
    end

    test "raises on wrong tuple size" do
      binary = :erlang.term_to_binary({:call, 1, %{}, :extra})

      assert_raise ArgumentError, fn ->
        Frame.decode!(binary)
      end
    end
  end

  describe "round-trip encoding for all types" do
    test "hello frame" do
      frame = Frame.new(:hello, %{protocol_version: 1, capabilities: [:calls]})
      assert_roundtrip(frame)
    end

    test "welcome frame" do
      frame = Frame.new(:welcome, %{protocol_version: 1, session_id: "abc"})
      assert_roundtrip(frame)
    end

    test "close frame" do
      frame = Frame.new(:close, %{reason: :shutdown})
      assert_roundtrip(frame)
    end

    test "call frame" do
      frame = Frame.new(:call, %{msg_id: "123", route: :test, args: %{a: 1}})
      assert_roundtrip(frame)
    end

    test "cast frame" do
      frame = Frame.new(:cast, %{route: :notify, args: %{event: :test}})
      assert_roundtrip(frame)
    end

    test "reply frame" do
      frame = Frame.new(:reply, %{msg_id: "123", result: :ok})
      assert_roundtrip(frame)
    end

    test "error frame" do
      frame = Frame.new(:error, %{msg_id: "123", reason: :not_found, detail: "missing"})
      assert_roundtrip(frame)
    end

    test "notify frame" do
      frame = Frame.new(:notify, %{event: :update, data: %{value: 42}})
      assert_roundtrip(frame)
    end

    test "discover frame" do
      frame = Frame.new(:discover, %{msg_id: "123"})
      assert_roundtrip(frame)
    end

    test "discover_reply frame" do
      frame = Frame.new(:discover_reply, %{msg_id: "123", routes: []})
      assert_roundtrip(frame)
    end

    test "heartbeat frame" do
      frame = Frame.new(:heartbeat, %{})
      assert_roundtrip(frame)
    end
  end

  describe "version handling" do
    test "preserves custom version through round-trip" do
      frame = Frame.new(:call, %{msg_id: "test"}, version: 5)
      {:ok, binary} = Frame.encode(frame)
      {:ok, decoded} = Frame.decode(binary)

      assert decoded.version == 5
    end

    test "accepts high version numbers" do
      frame = Frame.new(:reply, %{result: :ok}, version: 999)
      {:ok, binary} = Frame.encode(frame)
      {:ok, decoded} = Frame.decode(binary)

      assert decoded.version == 999
    end
  end

  describe "payload validation" do
    test "allows any valid map as payload" do
      payloads = [
        %{},
        %{a: 1},
        %{string: "value", atom: :atom},
        %{list: [1, 2, 3]},
        %{tuple: {1, 2}},
        %{nested: %{deep: %{very: :deep}}}
      ]

      for payload <- payloads do
        frame = Frame.new(:call, payload)
        {:ok, binary} = Frame.encode(frame)
        {:ok, decoded} = Frame.decode(binary)
        assert decoded.payload == payload
      end
    end
  end

  # Helper function
  defp assert_roundtrip(frame) do
    {:ok, binary} = Frame.encode(frame)
    {:ok, decoded} = Frame.decode(binary)

    assert decoded.type == frame.type
    assert decoded.version == frame.version
    assert decoded.payload == frame.payload
  end
end
