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
  end
end
