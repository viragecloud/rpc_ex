defmodule RpcEx.Router do
  @moduledoc """
  Declarative DSL for defining RPC handlers.

  Modules using this DSL can expose both `call` (request/response) and `cast`
  (fire-and-forget) endpoints. The DSL captures route metadata for discovery and
  provides introspection helpers used by the runtime.
  """

  @type middleware :: module() | {module(), keyword()}

  defmacro __using__(opts \\ []) do
    quote do
      import RpcEx.Router,
        only: [call: 1, call: 2, cast: 1, cast: 2, middleware: 1, middleware: 2]

      Module.register_attribute(__MODULE__, :rpc_routes, accumulate: true)
      Module.register_attribute(__MODULE__, :rpc_middlewares, accumulate: true)

      @rpc_router_options unquote(opts)

      @doc false
      def __rpc_dispatch__(kind, route, _args, _context, _opts) do
        RpcEx.Router.raise_unknown_route!(__MODULE__, kind, route)
      end

      defoverridable __rpc_dispatch__: 5

      @before_compile RpcEx.Router
    end
  end

  @doc """
  Declares middleware to be applied to subsequent routes.
  """
  defmacro middleware(module_or_tuple) do
    quote do
      @rpc_middlewares RpcEx.Router.normalize_middleware(unquote(module_or_tuple))
    end
  end

  defmacro middleware(module, opts) do
    quote do
      @rpc_middlewares {unquote(module), unquote(opts)}
    end
  end

  @doc """
  Defines a request/response RPC route.
  """
  defmacro call(name, do: block) do
    define_route(:call, name, [], block)
  end

  defmacro call(name, opts, do: block) when is_list(opts) do
    define_route(:call, name, opts, block)
  end

  @doc """
  Defines a fire-and-forget RPC route.
  """
  defmacro cast(name, do: block) do
    define_route(:cast, name, [], block)
  end

  defmacro cast(name, opts, do: block) when is_list(opts) do
    define_route(:cast, name, opts, block)
  end

  @doc false
  def normalize_middleware({module, opts}) when is_atom(module) and is_list(opts) do
    {module, opts}
  end

  def normalize_middleware(module) when is_atom(module), do: {module, []}

  def normalize_middleware(other) do
    raise ArgumentError, """
    invalid middleware specification: #{inspect(other)}
    Expected a module or {module, opts} tuple.
    """
  end

  @doc false
  def raise_unknown_route!(module, kind, route) do
    raise ArgumentError,
          "unknown #{kind} route #{inspect(route)} for router #{inspect(module)}"
  end

  defmacro __before_compile__(env) do
    routes = Module.get_attribute(env.module, :rpc_routes) |> Enum.reverse()
    middlewares = Module.get_attribute(env.module, :rpc_middlewares) |> Enum.reverse()
    router_opts = Module.get_attribute(env.module, :rpc_router_options) || []

    quote do
      @doc false
      def __rpc_routes__, do: unquote(Macro.escape(routes))

      @doc false
      def __rpc_middlewares__, do: unquote(Macro.escape(middlewares))

      @doc false
      def __rpc_router_options__, do: unquote(Macro.escape(router_opts))
    end
  end

  defp define_route(kind, name, opts, block) do
    args_var = Macro.var(:args, nil)
    context_var = Macro.var(:context, nil)
    options_var = Macro.var(:opts, nil)

    quote do
      def __rpc_dispatch__(
            unquote(kind),
            unquote(name),
            unquote(args_var),
            unquote(context_var),
            unquote(options_var)
          ) do
        unquote(block)
      end

      route = %RpcEx.Router.Route{
        name: unquote(name),
        kind: unquote(kind),
        handler: {__MODULE__, :__rpc_dispatch__, 5},
        options: unquote(opts),
        metadata: %{}
      }

      @rpc_routes route
    end
  end
end
