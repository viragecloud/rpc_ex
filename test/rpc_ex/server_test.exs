defmodule RpcEx.ServerTest do
  use ExUnit.Case, async: false

  alias RpcEx.Server

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
      spec = Server.child_spec(router: TestRouter, port: 4000)

      assert spec.id == RpcEx.Server
      assert spec.start == {Server, :start_link, [[router: TestRouter, port: 4000]]}
      assert spec.type == :supervisor
    end

    test "returns child spec with custom name" do
      spec = Server.child_spec(router: TestRouter, port: 4000, name: :custom_server)

      assert spec.id == :custom_server
    end
  end

  describe "start_link/1" do
    test "starts server with required options" do
      port = Enum.random(50_000..59_000)

      {:ok, pid} = Server.start_link(router: TestRouter, port: port)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "starts server with scheme :http" do
      port = Enum.random(50_000..59_000)

      {:ok, pid} = Server.start_link(router: TestRouter, port: port, scheme: :http)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "starts server with custom context" do
      port = Enum.random(50_000..59_000)

      {:ok, pid} =
        Server.start_link(router: TestRouter, port: port, context: %{custom: :data})

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "requires router option" do
      assert_raise KeyError, fn ->
        Server.start_link(port: 4000)
      end
    end

    test "starts with default port when not specified" do
      # Port defaults to 4000 when not specified
      {:ok, pid} = Server.start_link(router: TestRouter)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
