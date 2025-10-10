defmodule RpcEx.Protocol.HandshakeTest do
  use ExUnit.Case, async: true

  alias RpcEx.Protocol.Handshake

  describe "build/1" do
    test "creates handshake with defaults" do
      handshake = Handshake.build()

      assert handshake.protocol_version == 1
      assert handshake.supported_encodings == [:etf]
      assert handshake.compression == :enabled
      assert :calls in handshake.capabilities
      assert :casts in handshake.capabilities
      assert :discover in handshake.capabilities
      assert :notify in handshake.capabilities
    end

    test "accepts custom protocol_version" do
      handshake = Handshake.build(protocol_version: 2)
      assert handshake.protocol_version == 2
    end

    test "accepts custom compression" do
      handshake = Handshake.build(compression: :disabled)
      assert handshake.compression == :disabled
    end

    test "accepts custom capabilities" do
      handshake = Handshake.build(capabilities: [:calls, :casts])
      assert handshake.capabilities == [:calls, :casts]
    end

    test "accepts custom meta" do
      handshake = Handshake.build(meta: %{version: "1.0"})
      assert handshake.meta == %{version: "1.0"}
    end

    test "disables notifications when enable_notifications is false" do
      handshake = Handshake.build(enable_notifications: false)
      assert :calls in handshake.capabilities
      assert :casts in handshake.capabilities
      assert :discover in handshake.capabilities
      refute :notify in handshake.capabilities
    end
  end

  describe "negotiate/2" do
    test "successful negotiation with matching versions" do
      local = Handshake.build(protocol_version: 1)

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf],
        "capabilities" => [:calls, :casts]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.protocol_version == 1
      assert session.compression == :enabled
      assert session.encoding == :etf
      assert session.remote_capabilities == [:calls, :casts]
    end

    test "negotiates to minimum protocol version" do
      local = Handshake.build(protocol_version: 2)

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.protocol_version == 1
    end

    test "fails with incompatible protocol versions" do
      local = Handshake.build(protocol_version: 1)

      remote = %{
        "protocol_version" => 3,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:error, :unsupported_version} = Handshake.negotiate(local, remote)
    end

    test "fails when remote protocol version too old" do
      local = Handshake.build(protocol_version: 3)

      remote = %{
        "protocol_version" => 0,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:error, :unsupported_version} = Handshake.negotiate(local, remote)
    end

    test "negotiates compression when both enabled" do
      local = Handshake.build(compression: :enabled)

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.compression == :enabled
    end

    test "disables compression when local disabled" do
      local = Handshake.build(compression: :disabled)

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.compression == :disabled
    end

    test "disables compression when remote disabled" do
      local = Handshake.build(compression: :enabled)

      remote = %{
        "protocol_version" => 1,
        "compression" => :disabled,
        "supported_encodings" => [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.compression == :disabled
    end

    test "fails with no common encoding" do
      local = Handshake.build(supported_encodings: [:etf])

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:json, :msgpack]
      }

      assert {:error, :unsupported_encoding} = Handshake.negotiate(local, remote)
    end

    test "selects first common encoding" do
      local = Handshake.build(supported_encodings: [:etf, :json])

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:json, :etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.encoding == :json
    end

    test "handles error in remote payload" do
      local = Handshake.build()
      remote = %{"error" => "Connection rejected"}

      assert {:error, :rejected} = Handshake.negotiate(local, remote)
    end

    test "fails with missing protocol_version" do
      local = Handshake.build()

      remote = %{
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:error, :unsupported_version} = Handshake.negotiate(local, remote)
    end

    test "fails with invalid remote payload" do
      local = Handshake.build()
      remote = "invalid"

      assert {:error, :unsupported_version} = Handshake.negotiate(local, remote)
    end

    test "includes meta from both sides" do
      local = Handshake.build(meta: %{client_version: "1.0"})

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf],
        "meta" => %{server_version: "2.0"}
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.meta.local == %{client_version: "1.0"}
      assert session.meta.remote == %{server_version: "2.0"}
    end

    test "handles missing remote meta" do
      local = Handshake.build(meta: %{client_version: "1.0"})

      remote = %{
        "protocol_version" => 1,
        "compression" => :enabled,
        "supported_encodings" => [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.meta.local == %{client_version: "1.0"}
      assert session.meta.remote == %{}
    end

    test "normalizes atom keys to strings in remote payload" do
      local = Handshake.build()

      remote = %{
        protocol_version: 1,
        compression: :enabled,
        supported_encodings: [:etf]
      }

      assert {:ok, session} = Handshake.negotiate(local, remote)
      assert session.protocol_version == 1
    end
  end
end
