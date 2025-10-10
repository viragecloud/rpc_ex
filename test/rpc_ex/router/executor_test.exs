defmodule RpcEx.Router.ExecutorTest do
  use ExUnit.Case, async: true

  alias RpcEx.Router.Executor

  defmodule TestRouter do
    use RpcEx.Router

    middleware RpcEx.Test.Middlewares.Trace, tag: :foo

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

    middleware RpcEx.Test.Middlewares.Halt, reason: :blocked

    call :restricted do
      _ = args
      _ = context
      _ = opts
      Process.put(:handler_invoked?, true)
      :restricted
    end
  end

  defmodule ErrorRouter do
    use RpcEx.Router

    call :raises do
      _ = args
      _ = context
      _ = opts
      raise "handler error"
    end

    call :throws do
      _ = args
      _ = context
      _ = opts
      throw({:custom_throw, :value})
    end

    call :exits do
      _ = args
      _ = context
      _ = opts
      exit(:handler_exit)
    end
  end

  defmodule ReplaceMiddleware do
    def before(:call, _route, args, context, opts) do
      new_args = Map.put(args, :replaced, opts[:value])
      {:replace, new_args, Map.put(context, :replaced, true)}
    end

    def after_handle(:call, _route, result, context, _opts) do
      {:cont, {:wrapped, result}, Map.put(context, :after_called, true)}
    end
  end

  defmodule RouterWithReplace do
    use RpcEx.Router

    middleware ReplaceMiddleware, value: :replaced_value

    call :test do
      _ = context
      _ = opts
      {:ok, args}
    end
  end

  defmodule InvalidBeforeMiddleware do
    def before(:call, _route, _args, _context, _opts) do
      :invalid_return
    end
  end

  defmodule InvalidAfterMiddleware do
    def after_handle(:call, _route, _result, _context, _opts) do
      :invalid_return
    end
  end

  defmodule RouterWithInvalidBefore do
    use RpcEx.Router

    middleware InvalidBeforeMiddleware

    call :test do
      _ = args
      _ = context
      _ = opts
      :ok
    end
  end

  defmodule RouterWithInvalidAfter do
    use RpcEx.Router

    middleware InvalidAfterMiddleware

    call :test do
      _ = args
      _ = context
      _ = opts
      :ok
    end
  end

  defmodule NoFunctionsMiddleware do
    # Middleware with no before/after functions
  end

  defmodule OnlyAfterMiddleware do
    def after_handle(:call, _route, result, context, _opts) do
      {:cont, result, Map.put(context, :only_after, true)}
    end
  end

  defmodule RouterWithOnlyAfter do
    use RpcEx.Router

    middleware OnlyAfterMiddleware

    call :test do
      _ = args
      _ = context
      _ = opts
      {:ok, :result}
    end
  end

  defmodule RouterWithNoFunctions do
    use RpcEx.Router

    middleware NoFunctionsMiddleware

    call :test do
      _ = args
      _ = context
      _ = opts
      {:ok, :result}
    end
  end

  describe "dispatch/6" do
    test "invokes call handler with middleware pipeline" do
      args = %{message: "hi"}
      {:ok, result, ctx} = Executor.dispatch(TestRouter, :call, :echo, args, %{}, timeout: 1000)

      assert {:ok, {%{message: "hi", trace: :foo}, %{trace: :foo}, [timeout: 1000]}} = result

      assert ctx == %{trace: :foo}
    end

    test "invokes cast handler without middleware context modifications" do
      args = %{value: 10}
      {:ok, result, ctx} = Executor.dispatch(TestRouter, :cast, :notify, args)

      assert {:cast, %{value: 10, trace: :foo}} = result
      assert ctx == %{trace: :foo}
    end

    test "halts execution when middleware requests it" do
      args = %{}

      routes = HaltingRouter.__rpc_routes__()

      assert Enum.any?(routes, fn route ->
               route.name == :restricted and
                 route.middlewares == [{RpcEx.Test.Middlewares.Halt, [reason: :blocked]}]
             end)

      assert {:halt, {:after_halt, {:halted, :blocked}}, %{after: true, halted: true}} =
               Executor.dispatch(HaltingRouter, :call, :restricted, args, %{})

      refute Process.get(:handler_invoked?)
    end

    test "returns error for unknown routes" do
      assert {:error, {:unknown_route, {TestRouter, :call, :unknown}}} =
               Executor.dispatch(TestRouter, :call, :unknown, %{})
    end

    test "handles nil context" do
      {:ok, result, ctx} = Executor.dispatch(TestRouter, :call, :echo, %{}, nil)
      assert is_tuple(result)
      assert is_map(ctx)
    end

    test "normalizes invalid context to empty map" do
      {:ok, _result, ctx} = Executor.dispatch(TestRouter, :call, :echo, %{}, :invalid_context)
      assert is_map(ctx)
    end

    test "merges route options with dispatch options" do
      {:ok, result, _ctx} = Executor.dispatch(TestRouter, :call, :echo, %{}, %{}, timeout: 1000)
      assert {:ok, {_args, _ctx, opts}} = result
      # Route has timeout: 5000, dispatch has timeout: 1000
      # Dispatch opts should override
      assert opts[:timeout] == 1000
    end
  end

  describe "middleware replace behavior" do
    test "middleware can replace args and modify context" do
      {:ok, result, ctx} = Executor.dispatch(RouterWithReplace, :call, :test, %{original: :value})

      assert {:wrapped, {:ok, %{original: :value, replaced: :replaced_value}}} = result
      assert ctx.replaced == true
      assert ctx.after_called == true
    end
  end

  describe "middleware without functions" do
    test "middleware with no functions is skipped" do
      {:ok, result, _ctx} = Executor.dispatch(RouterWithNoFunctions, :call, :test, %{})
      assert {:ok, :result} = result
    end

    test "middleware with only after_handle is called" do
      {:ok, result, ctx} = Executor.dispatch(RouterWithOnlyAfter, :call, :test, %{})
      assert {:ok, :result} = result
      assert ctx.only_after == true
    end
  end

  describe "error handling" do
    test "propagates exceptions from handlers" do
      assert_raise RuntimeError, "handler error", fn ->
        Executor.dispatch(ErrorRouter, :call, :raises, %{})
      end
    end

    test "propagates throws from handlers" do
      assert catch_throw(Executor.dispatch(ErrorRouter, :call, :throws, %{})) ==
               {:custom_throw, :value}
    end

    test "propagates exits from handlers" do
      assert catch_exit(Executor.dispatch(ErrorRouter, :call, :exits, %{})) == :handler_exit
    end
  end

  describe "invalid middleware returns" do
    test "raises ArgumentError for invalid before return" do
      assert_raise ArgumentError, ~r/invalid return.*before/, fn ->
        Executor.dispatch(RouterWithInvalidBefore, :call, :test, %{})
      end
    end

    test "raises ArgumentError for invalid after_handle return" do
      assert_raise ArgumentError, ~r/invalid return.*after_handle/, fn ->
        Executor.dispatch(RouterWithInvalidAfter, :call, :test, %{})
      end
    end
  end

  describe "route lookup" do
    test "returns error for non-existent route" do
      assert {:error, {:unknown_route, {TestRouter, :call, :nonexistent}}} =
               Executor.dispatch(TestRouter, :call, :nonexistent, %{})
    end

    test "distinguishes between call and cast routes" do
      # :notify is a cast route
      assert {:error, {:unknown_route, {TestRouter, :call, :notify}}} =
               Executor.dispatch(TestRouter, :call, :notify, %{})

      # :echo is a call route
      assert {:error, {:unknown_route, {TestRouter, :cast, :echo}}} =
               Executor.dispatch(TestRouter, :cast, :echo, %{})
    end

    test "returns error for invalid router" do
      assert {:error, {:unknown_route, {NonExistentRouter, :call, :test}}} =
               Executor.dispatch(NonExistentRouter, :call, :test, %{})
    end
  end

  describe "context handling" do
    test "preserves context through handler execution" do
      initial_ctx = %{user_id: 123, session: "abc"}
      {:ok, _result, ctx} = Executor.dispatch(TestRouter, :call, :echo, %{}, initial_ctx)

      # Context is modified by middleware but original keys preserved
      assert is_map(ctx)
    end

    test "middleware can modify context" do
      {:ok, _result, ctx} = Executor.dispatch(TestRouter, :call, :echo, %{})
      assert ctx.trace == :foo
    end
  end

  describe "options handling" do
    test "passes options to handler" do
      custom_opts = [custom: :value, timeout: 2000]
      {:ok, result, _ctx} = Executor.dispatch(TestRouter, :call, :echo, %{}, %{}, custom_opts)

      assert {:ok, {_args, _ctx, opts}} = result
      assert opts[:custom] == :value
    end

    test "route options and dispatch options are merged" do
      # TestRouter :echo has timeout: 5_000
      {:ok, result, _ctx} =
        Executor.dispatch(TestRouter, :call, :echo, %{}, %{}, another_opt: :value)

      assert {:ok, {_args, _ctx, opts}} = result
      assert Keyword.has_key?(opts, :timeout)
      assert opts[:another_opt] == :value
    end
  end
end
