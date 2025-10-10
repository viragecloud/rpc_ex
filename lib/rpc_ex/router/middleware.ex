defmodule RpcEx.Router.Middleware do
  @moduledoc """
  Behaviour for router middleware modules.

  Middleware modules can intercept RPC requests before and after handler
  execution to implement cross-cutting concerns such as authentication,
  tracing, instrumentation, or payload shaping.

  ## Example

      defmodule MyApp.AuthMiddleware do
        @behaviour RpcEx.Router.Middleware

        def before(_kind, _route, args, context, opts) do
          required_role = Keyword.get(opts, :role)

          if authorized?(context, required_role) do
            {:cont, context}
          else
            {:halt, {:error, :unauthorized}, context}
          end
        end

        def after_handle(_kind, _route, response, context, _opts) do
          # Log successful authorization
          Logger.debug("Request completed for user: \#{context.user_id}")
          {:cont, response, context}
        end

        defp authorized?(%{user: user}, role) do
          role in user.roles
        end
      end

      # Use in router
      defmodule MyApp.Router do
        use RpcEx.Router

        middleware MyApp.AuthMiddleware, role: :admin

        call :delete_user do
          # Only executed if user has :admin role
          {:ok, :deleted}
        end
      end

  ## Middleware Chain

  Multiple middleware modules are executed in the order they are declared.
  The `before/5` callbacks execute top-down, and `after_handle/5` callbacks
  execute bottom-up (like a stack).
  """

  @typedoc "The stage at which middleware is invoked."
  @type stage :: :before | :after | :around

  @typedoc "Return type for middleware callbacks."
  @type middleware_result ::
          {:cont, map()}
          | {:halt, term()}
          | {:replace, term(), map()}

  @doc """
  Invoked prior to executing a handler.

  Returning `{:cont, context}` continues to the next middleware/handler.
  Returning `{:halt, response}` prevents handler execution and returns `response`.
  Returning `{:replace, new_args, context}` swaps handler arguments.
  """
  @callback before(RpcEx.Router.Route.kind(), RpcEx.route(), term(), map(), keyword()) ::
              middleware_result()

  @doc """
  Invoked after handler completion.

  Returning `{:cont, response, context}` continues to next middleware.
  Returning `{:halt, response}` stops propagation and returns `response`.
  """
  @callback after_handle(RpcEx.Router.Route.kind(), RpcEx.route(), term(), map(), keyword()) ::
              {:cont, term(), map()} | {:halt, term()}

  @optional_callbacks before: 5, after_handle: 5
end
