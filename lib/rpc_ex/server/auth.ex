defmodule RpcEx.Server.Auth do
  @moduledoc """
  Behaviour for implementing authentication during the WebSocket handshake.

  Authentication modules validate client credentials provided in the `:hello`
  frame and return context to be injected into the connection for use by handlers.

  ## Example

      defmodule MyApp.TokenAuth do
        @behaviour RpcEx.Server.Auth

        @impl true
        def authenticate(credentials, _opts) do
          case validate_token(credentials) do
            {:ok, user} ->
              # Return context that will be merged into handler context
              {:ok, %{user: user, user_id: user.id, roles: user.roles}}

            {:error, reason} ->
              {:error, :invalid_token, "Token validation failed: \#{reason}"}
          end
        end

        defp validate_token(%{"token" => token}) do
          # Your token validation logic
          MyApp.Accounts.verify_token(token)
        end

        defp validate_token(_), do: {:error, :missing_token}
      end

  ## Usage

  Configure the server with your auth module:

      RpcEx.Server.start_link(
        router: MyApp.Router,
        port: 4000,
        auth: {MyApp.TokenAuth, []}
      )

  ## Client Side

  Clients pass credentials in the handshake:

      RpcEx.Client.start_link(
        url: "ws://localhost:4000",
        handshake: [
          meta: %{
            "auth" => %{
              "token" => "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
            }
          }
        ]
      )

  ## Handler Access

  Authenticated context is available in all handlers:

      call :get_profile do
        # context.user, context.user_id, context.roles are available
        user_id = context.user_id
        {:ok, MyApp.Users.get_profile(user_id)}
      end
  """

  @typedoc """
  Credentials provided by the client during handshake.

  Typically extracted from the `:hello` frame's metadata under an "auth" key.
  """
  @type credentials :: map() | nil

  @typedoc """
  Authentication context to be merged into the connection context.

  This context will be available to all route handlers via the `context` variable.
  """
  @type auth_context :: map()

  @typedoc """
  Error reason atom (e.g., `:invalid_token`, `:expired`, `:unauthorized`).
  """
  @type error_reason :: atom()

  @typedoc """
  Human-readable error detail string.
  """
  @type error_detail :: String.t()

  @doc """
  Validates client credentials and returns authentication context.

  ## Parameters

  - `credentials` - Credentials map from client's handshake metadata
  - `opts` - Options passed when configuring the auth module

  ## Returns

  - `{:ok, auth_context}` - Authentication successful, merge context into connection
  - `{:error, reason}` - Authentication failed with reason atom
  - `{:error, reason, detail}` - Authentication failed with reason and detail message

  ## Examples

      # Successful authentication
      def authenticate(%{"token" => token}, _opts) do
        case verify_token(token) do
          {:ok, user} -> {:ok, %{user: user, user_id: user.id}}
          {:error, _} -> {:error, :invalid_token}
        end
      end

      # With detailed error
      def authenticate(credentials, _opts) do
        if valid?(credentials) do
          {:ok, %{authenticated: true}}
        else
          {:error, :unauthorized, "Invalid credentials provided"}
        end
      end

      # No authentication required (passthrough)
      def authenticate(_credentials, _opts) do
        {:ok, %{}}
      end
  """
  @callback authenticate(credentials(), keyword()) ::
              {:ok, auth_context()}
              | {:error, error_reason()}
              | {:error, error_reason(), error_detail()}
end
