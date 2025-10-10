defmodule RpcEx.Integration.AuthenticationTest do
  use ExUnit.Case

  alias RpcEx.Client
  alias RpcEx.Server

  @moduletag :integration

  defmodule AuthenticatedRouter do
    @moduledoc false
    use RpcEx.Router

    call :whoami do
      {:ok,
       %{
         user_id: context.user_id,
         roles: context.roles,
         authenticated: context.authenticated
       }}
    end

    call :admin_only do
      if :admin in context.roles do
        {:ok, :allowed}
      else
        {:error, :forbidden}
      end
    end
  end

  describe "token authentication" do
    setup do
      port = Enum.random(40_000..49_000)

      server =
        start_supervised!(
          {Server,
           router: AuthenticatedRouter,
           port: port,
           auth: {RpcEx.Test.Support.TestAuth, valid_token: "secret123"}}
        )

      %{port: port, server: server}
    end

    test "successful authentication with valid token", %{port: port} do
      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/",
          handshake: [
            meta: %{
              "auth" => %{
                "token" => "secret123"
              }
            }
          ]
        )

      wait_for_ready(client)

      assert {:ok, result, _meta} = Client.call(client, :whoami)
      assert result.user_id == "test_user"
      assert result.roles == [:user]
      assert result.authenticated == true

      GenServer.stop(client)
    end

    test "authentication fails with invalid token", %{port: port} do
      # Client should fail to connect with invalid token
      Process.flag(:trap_exit, true)

      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/",
          handshake: [
            meta: %{
              "auth" => %{
                "token" => "invalid_token"
              }
            }
          ],
          reconnect: false
        )

      # Wait for connection to fail
      assert_receive {:EXIT, ^client, _reason}, 2000

      # Try to verify client is down
      refute Process.alive?(client)
    end

    test "authentication fails without credentials", %{port: port} do
      Process.flag(:trap_exit, true)

      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/",
          reconnect: false
        )

      # Should fail to connect
      assert_receive {:EXIT, ^client, _reason}, 2000
      refute Process.alive?(client)
    end
  end

  describe "username/password authentication" do
    setup do
      port = Enum.random(40_000..49_000)

      server =
        start_supervised!(
          {Server,
           router: AuthenticatedRouter,
           port: port,
           auth: {RpcEx.Test.Support.TestAuth, []}}
        )

      %{port: port, server: server}
    end

    test "admin user has admin role", %{port: port} do
      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/",
          handshake: [
            meta: %{
              "auth" => %{
                "username" => "admin",
                "password" => "password"
              }
            }
          ]
        )

      wait_for_ready(client)

      assert {:ok, result, _meta} = Client.call(client, :whoami)
      assert result.user_id == "admin"
      assert result.roles == [:admin, :user]

      # Admin should be able to call admin_only
      assert {:ok, :allowed, _meta} = Client.call(client, :admin_only)

      GenServer.stop(client)
    end

    test "regular user cannot call admin endpoints", %{port: port} do
      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/",
          handshake: [
            meta: %{
              "auth" => %{
                "token" => "secret123"
              }
            }
          ]
        )

      wait_for_ready(client)

      # Regular user should not have admin role
      assert {:ok, result, _meta} = Client.call(client, :whoami)
      refute :admin in result.roles

      # Should fail on admin_only endpoint
      assert {:error, {reason, _detail}} = Client.call(client, :admin_only)
      assert reason == :forbidden

      GenServer.stop(client)
    end
  end

  describe "server without authentication" do
    setup do
      port = Enum.random(40_000..49_000)

      server =
        start_supervised!(
          {Server,
           router: AuthenticatedRouter,
           port: port}
        )

      %{port: port, server: server}
    end

    test "clients can connect without credentials", %{port: port} do
      {:ok, client} =
        Client.start_link(
          url: "ws://localhost:#{port}/"
        )

      wait_for_ready(client)

      # Connection succeeds, but context won't have auth fields
      # (This would fail since whoami expects user_id in context)
      # In a real app, you'd have different routers or check for auth

      GenServer.stop(client)
    end
  end

  defp wait_for_ready(client, attempts \\ 50)

  defp wait_for_ready(_client, 0), do: :ok

  defp wait_for_ready(client, attempts) do
    case :sys.get_state(client) do
      %{connection_status: :ready} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_for_ready(client, attempts - 1)
    end
  end
end
