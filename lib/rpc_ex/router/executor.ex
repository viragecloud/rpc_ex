defmodule RpcEx.Router.Executor do
  @moduledoc """
  Executes router handlers through the configured middleware pipeline.

  This module powers the runtime path for both client and server dispatch. It
  is responsible for locating route definitions, running `before` callbacks,
  invoking the handler, and unwinding `after_handle` callbacks while preserving
  context updates.
  """

  alias RpcEx.Router.Route

  @type dispatch_result ::
          {:ok, term(), map()}
          | {:halt, term(), map()}
          | {:error, {:unknown_route, {module(), Route.kind(), RpcEx.route()}}}

  @doc """
  Dispatches a request to the given router.

  Returns `{:ok, result, context}` when the handler completes, `{:halt, result, context}`
  when a middleware halts execution, or `{:error, {:unknown_route, ...}}` when the route
  does not exist.
  """
  @spec dispatch(module(), Route.kind(), RpcEx.route(), term(), map() | nil, keyword()) ::
          dispatch_result()
  def dispatch(router, kind, route_name, args \\ %{}, context \\ %{}, opts \\ []) do
    case lookup_route(router, kind, route_name) do
      {:ok, %Route{} = route} ->
        do_dispatch(router, route, kind, route_name, args, normalize_context(context), opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_dispatch(router, route, kind, route_name, args, context, opts) do
    dispatch_opts = Keyword.merge(route.options, opts)
    middlewares = route.middlewares || []

    case run_before(middlewares, kind, route_name, args, context) do
      {:halt, response, ctx, executed} ->
        {final_result, final_ctx} = run_after(executed, kind, route_name, response, ctx)
        {:halt, final_result, final_ctx}

      {:ok, updated_args, updated_ctx, executed} ->
        execute_handler(
          router,
          route,
          kind,
          route_name,
          updated_args,
          updated_ctx,
          dispatch_opts,
          executed
        )
    end
  end

  defp execute_handler(router, _route, kind, route_name, args, context, opts, executed) do
    result =
      try do
        router.__rpc_dispatch__(kind, route_name, args, context, opts)
      rescue
        exception ->
          {_ignored, _ctx} =
            run_after(executed, kind, route_name, {:error, exception}, context)

          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          {_ignored, _ctx} =
            run_after(executed, kind, route_name, {:error, {kind, reason}}, context)

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {final_result, final_ctx} = run_after(executed, kind, route_name, result, context)
    {:ok, final_result, final_ctx}
  end

  defp lookup_route(router, kind, route_name) do
    router.__rpc_routes__()
    |> Enum.find(fn %Route{name: name, kind: route_kind} ->
      route_name == name and route_kind == kind
    end)
    |> case do
      %Route{} = route -> {:ok, route}
      _ -> {:error, {:unknown_route, {router, kind, route_name}}}
    end
  rescue
    _ -> {:error, {:unknown_route, {router, kind, route_name}}}
  end

  defp run_before(middlewares, kind, route_name, args, context) do
    Enum.reduce_while(middlewares, {:ok, args, context, []}, fn middleware,
                                                                {:ok, curr_args, curr_ctx, stack} ->
      {module, mw_opts} = middleware
      _ = Code.ensure_loaded?(module)
      before_exported? = function_exported?(module, :before, 5)
      after_exported? = function_exported?(module, :after_handle, 5)
      stack_entry = {module, mw_opts}
      updated_stack = if after_exported?, do: [stack_entry | stack], else: stack

      reduce_before_stage(
        %{module: module, mw_opts: mw_opts, before?: before_exported?, after?: after_exported?},
        %{
          kind: kind,
          route: route_name,
          args: curr_args,
          ctx: curr_ctx,
          stack: stack,
          updated_stack: updated_stack
        }
      )
    end)
  end

  defp reduce_before_stage(%{before?: true} = state, params) do
    %{module: module, mw_opts: mw_opts} = state
    %{kind: kind, route: route, args: args, ctx: ctx, updated_stack: updated_stack} = params

    case module.before(kind, route, args, ctx, mw_opts) do
      {:cont, new_ctx} when is_map(new_ctx) ->
        {:cont, {:ok, args, new_ctx, updated_stack}}

      {:replace, new_args, new_ctx} when is_map(new_ctx) ->
        {:cont, {:ok, new_args, new_ctx, updated_stack}}

      {:halt, response} ->
        {:halt, {:halt, response, ctx, updated_stack}}

      {:halt, response, new_ctx} when is_map(new_ctx) ->
        {:halt, {:halt, response, new_ctx, updated_stack}}

      other ->
        raise ArgumentError,
              "invalid return from #{inspect(module)}.before/5: #{inspect(other)}"
    end
  end

  defp reduce_before_stage(%{before?: false, after?: true}, %{
         args: args,
         ctx: ctx,
         updated_stack: updated_stack
       }) do
    {:cont, {:ok, args, ctx, updated_stack}}
  end

  defp reduce_before_stage(_state, %{args: args, ctx: ctx, stack: stack}) do
    {:cont, {:ok, args, ctx, stack}}
  end

  defp run_after([], _kind, _route, result, context), do: {result, context}

  defp run_after([{module, mw_opts} | rest], kind, route, result, context) do
    if function_exported?(module, :after_handle, 5) do
      case module.after_handle(kind, route, result, context, mw_opts) do
        {:cont, new_result, new_ctx} when is_map(new_ctx) ->
          run_after(rest, kind, route, new_result, new_ctx)

        {:halt, new_result} ->
          {new_result, context}

        {:halt, new_result, new_ctx} when is_map(new_ctx) ->
          {new_result, new_ctx}

        other ->
          raise ArgumentError,
                "invalid return from #{inspect(module)}.after_handle/5: #{inspect(other)}"
      end
    else
      run_after(rest, kind, route, result, context)
    end
  end

  defp normalize_context(nil), do: %{}
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_), do: %{}
end
