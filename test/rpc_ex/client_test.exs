defmodule RpcEx.ClientTest do
  use ExUnit.Case, async: false

  alias RpcEx.Client

  defmodule TestRouter do
    use RpcEx.Router

    call :ping do
      _ = args
      _ = context
      _ = opts
      {:ok, :pong}
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec with default options" do
      spec = Client.child_spec(url: "ws://localhost:4000")

      assert spec.id == RpcEx.Client
      assert spec.start == {Client, :start_link, [[url: "ws://localhost:4000"]]}
      assert spec.type == :worker
      assert spec.restart == :permanent
    end

    test "returns child spec with custom name" do
      spec = Client.child_spec(url: "ws://localhost:4000", name: :my_client)

      assert spec.id == :my_client
    end
  end

  describe "call/3 when not connected" do
    test "returns error when client not connected" do
      {:ok, client} = Client.start_link(url: "ws://localhost:19999", router: TestRouter)

      # Wait a bit for connection to fail
      Process.sleep(100)

      assert {:error, :not_connected} = Client.call(client, :ping)

      GenServer.stop(client)
    end
  end

  describe "cast/3 when not connected" do
    test "returns error when client not connected" do
      {:ok, client} = Client.start_link(url: "ws://localhost:19999", router: TestRouter)

      # Wait a bit for connection to fail
      Process.sleep(100)

      assert {:error, :not_connected} = Client.cast(client, :some_cast)

      GenServer.stop(client)
    end
  end

  describe "discover/2 when not connected" do
    test "returns error when client not connected" do
      {:ok, client} = Client.start_link(url: "ws://localhost:19999", router: TestRouter)

      # Wait a bit for connection to fail
      Process.sleep(100)

      assert {:error, :not_connected} = Client.discover(client)

      GenServer.stop(client)
    end
  end

  describe "stream/3 when not connected" do
    test "returns error when client not connected" do
      {:ok, client} = Client.start_link(url: "ws://localhost:19999", router: TestRouter)

      # Wait a bit for connection to fail
      Process.sleep(100)

      assert {:error, :not_connected} = Client.stream(client, :some_stream)

      GenServer.stop(client)
    end
  end
end
