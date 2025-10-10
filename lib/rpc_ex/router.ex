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
        only: [call: 2, call: 3, cast: 2, cast: 3, middleware: 1, middleware: 2]

      Module.register_attribute(__MODULE__, :rpc_routes, accumulate: true, persist: true)
      Module.register_attribute(__MODULE__, :rpc_middlewares, accumulate: true, persist: true)
      Module.register_attribute(__MODULE__, :rpc_middleware_chain, persist: true)

      Module.put_attribute(__MODULE__, :rpc_middleware_chain, [])

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
    expanded = Macro.expand(module_or_tuple, __CALLER__)
    {value, _binding} = Code.eval_quoted(expanded, [], __CALLER__)
    middleware = normalize_middleware(value)
    register_middleware(__CALLER__.module, middleware)

    quote do
      :ok
    end
  end

  defmacro middleware(module, opts) do
    quote do
      unquote(__MODULE__).middleware({unquote(module), unquote(opts)})
    end
  end

  @doc """
  Defines a request/response RPC route.
  """
  defmacro call(name, do: block) do
    define_route(:call, name, [], block, __CALLER__)
  end

  defmacro call(name, opts, do: block) when is_list(opts) do
    define_route(:call, name, opts, block, __CALLER__)
  end

  @doc """
  Defines a fire-and-forget RPC route.
  """
  defmacro cast(name, do: block) do
    define_route(:cast, name, [], block, __CALLER__)
  end

  defmacro cast(name, opts, do: block) when is_list(opts) do
    define_route(:cast, name, opts, block, __CALLER__)
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

  defp register_middleware(module, middleware) do
    Module.put_attribute(module, :rpc_middlewares, middleware)

    chain = Module.get_attribute(module, :rpc_middleware_chain) || []
    Module.put_attribute(module, :rpc_middleware_chain, chain ++ [middleware])
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

  defp define_route(kind, name, opts, block, %Macro.Env{} = env) do
    middlewares =
      env.module
      |> Module.get_attribute(:rpc_middleware_chain)
      |> case do
        nil -> []
        list when is_list(list) -> list
      end

    quote do
      def __rpc_dispatch__(unquote(kind), unquote(name), args, context, opts) do
        var!(args) = args
        var!(context) = context
        var!(opts) = opts
        unquote(block)
      end

      route = %RpcEx.Router.Route{
        name: unquote(name),
        kind: unquote(kind),
        handler: {__MODULE__, :__rpc_dispatch__, 5},
        options: unquote(Macro.escape(opts)),
        middlewares: unquote(Macro.escape(middlewares)),
        metadata: %{}
      }

      @rpc_routes route
    end
  end
end
