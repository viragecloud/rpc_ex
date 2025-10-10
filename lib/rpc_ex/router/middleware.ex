defmodule RpcEx.Router.Middleware do
  @moduledoc """
  Behaviour for router middleware modules.

  Middleware modules can intercept RPC requests before and after handler
  execution to implement cross-cutting concerns such as authentication,
  tracing, instrumentation, or payload shaping.
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
