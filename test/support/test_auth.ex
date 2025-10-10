defmodule RpcEx.Test.Support.TestAuth do
  @moduledoc false
  @behaviour RpcEx.Server.Auth

  @impl true
  def authenticate(credentials, opts) do
    required_token = Keyword.get(opts, :valid_token, "secret123")

    case credentials do
      %{"token" => ^required_token} ->
        {:ok, %{authenticated: true, user_id: "test_user", roles: [:user]}}

      %{"token" => token} when is_binary(token) ->
        {:error, :invalid_token, "Token '#{token}' is not valid"}

      %{"username" => username, "password" => password} ->
        if username == "admin" and password == "password" do
          {:ok, %{authenticated: true, user_id: username, roles: [:admin, :user]}}
        else
          {:error, :invalid_credentials}
        end

      nil ->
        {:error, :missing_credentials, "No authentication credentials provided"}

      _ ->
        {:error, :invalid_auth_format}
    end
  end
end
