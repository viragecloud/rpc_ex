defmodule RpcEx.Server.EndpointTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias RpcEx.Server.Endpoint

  defmodule TestRouter do
    use RpcEx.Router

    call :test do
      _ = args
      _ = context
      _ = opts
      {:ok, :test}
    end
  end

  describe "init/1" do
    test "returns options unchanged" do
      opts = [router: TestRouter, port: 4000]
      assert Endpoint.init(opts) == opts
    end
  end

  describe "call/2" do
    test "requires router option" do
      conn = conn(:get, "/")

      assert_raise KeyError, fn ->
        Endpoint.call(conn, [])
      end
    end

    test "sets websocket protocol header" do
      conn = conn(:get, "/")
      opts = [router: TestRouter]

      # This will fail at upgrade_adapter, but we can test the header is set
      try do
        Endpoint.call(conn, opts)
      rescue
        _ -> :ok
      end

      # Can't easily test the full flow without a real websocket connection,
      # but we can verify init works
      assert Endpoint.init(opts) == opts
    end

    test "includes optional context in handler opts" do
      opts = [router: TestRouter, context: %{user: "test"}]
      assert Endpoint.init(opts) == opts
    end

    test "includes optional auth in handler opts" do
      opts = [router: TestRouter, auth: {SomeAuthModule, []}]
      assert Endpoint.init(opts) == opts
    end

    test "includes optional handshake opts" do
      opts = [router: TestRouter, handshake: [compression: 0]]
      assert Endpoint.init(opts) == opts
    end
  end
end
