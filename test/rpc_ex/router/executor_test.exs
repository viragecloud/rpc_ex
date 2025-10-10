defmodule RpcEx.Router.ExecutorTest do
  use ExUnit.Case, async: true

  alias RpcEx.Router.Executor

  defmodule TestMiddleware.Trace do
    @behaviour RpcEx.Router.Middleware

    def before(_kind, _route, args, context, opts) do
      tag = Keyword.fetch!(opts, :tag)
      new_args = Map.put(args, :trace, tag)
      new_context = Map.put(context, :trace, tag)
      {:replace, new_args, new_context}
    end

    def after_handle(_kind, _route, response, context, _opts) do
      {:cont, {:post, response, context[:trace]}, context}
    end
  end

  defmodule TestMiddleware.Halt do
    @behaviour RpcEx.Router.Middleware

    def before(_kind, _route, _args, context, opts) do
      reason = Keyword.get(opts, :reason, :halted)
      new_context = Map.put(context, :halted, true)
      {:halt, {:halted, reason}, new_context}
    end

    def after_handle(_kind, _route, response, context, _opts) do
      {:cont, {:after_halt, response}, Map.put(context, :after, true)}
    end
  end

  defmodule TestRouter do
    use RpcEx.Router

    middleware TestMiddleware.Trace, tag: :foo

    call :echo, timeout: 5_000 do
      _ = context
      {:ok, {args, context, opts}}
    end

    cast :notify do
      _ = context
      _ = opts
      {:cast, args}
    end
  end

  defmodule HaltingRouter do
    use RpcEx.Router

    middleware TestMiddleware.Halt, reason: :blocked

    call :restricted do
      _ = args
      _ = context
      _ = opts
      Process.put(:handler_invoked?, true)
      :restricted
    end
  end

  describe "dispatch/6" do
    test "invokes call handler with middleware pipeline" do
      args = %{message: "hi"}
      {:ok, result, ctx} = Executor.dispatch(TestRouter, :call, :echo, args, %{}, timeout: 1000)

      assert {:post, {:ok, {%{message: "hi", trace: :foo}, %{trace: :foo}, [timeout: 1000]}},
              :foo} = result

      assert ctx == %{trace: :foo}
    end

    test "invokes cast handler without middleware context modifications" do
      args = %{value: 10}
      {:ok, result, ctx} = Executor.dispatch(TestRouter, :cast, :notify, args)

      assert {:post, {:cast, %{value: 10, trace: :foo}}, :foo} = result
      assert ctx == %{trace: :foo}
    end

    test "halts execution when middleware requests it" do
      args = %{}

      assert {:halt, {:after_halt, {:halted, :blocked}}, %{after: true, halted: true}} =
               Executor.dispatch(HaltingRouter, :call, :restricted, args, %{})

      refute Process.get(:handler_invoked?)
    end

    test "returns error for unknown routes" do
      assert {:error, {:unknown_route, {TestRouter, :call, :unknown}}} =
               Executor.dispatch(TestRouter, :call, :unknown, %{})
    end
  end
end
