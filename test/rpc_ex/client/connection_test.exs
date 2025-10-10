defmodule RpcEx.Client.ConnectionTest do
  use ExUnit.Case, async: true

  alias RpcEx.Client.Connection
  alias RpcEx.Protocol.Frame

  defmodule ClientRouter do
    use RpcEx.Router

    middleware RpcEx.Test.Middlewares.Trace, tag: :client

    call :flush do
      _ = args
      _ = context
      _ = opts
      {:reply, :flushed}
    end

    cast :invalidate do
      _ = context
      _ = opts
      {:notify, %{event: :invalidate, payload: args}}
    end
  end

  describe "handle_frame/2" do
    test "handles server initiated call" do
      frame = Frame.new(:call, %{msg_id: "1", route: :flush})

      {:reply, reply, new_state} = Connection.handle_frame(frame, new_state())

      assert %Frame{type: :reply, payload: %{msg_id: "1", result: :flushed}} = reply
      assert new_state.context[:session] == %{role: :server}
    end

    test "handles server initiated cast" do
      frame = Frame.new(:cast, %{route: :invalidate, args: %{keys: [1]}})

      {:push, notify, new_state} = Connection.handle_frame(frame, new_state())

      assert %Frame{
               type: :notify,
               payload: %{event: :invalidate, payload: %{keys: [1]}, route: :invalidate}
             } = notify

      assert new_state.context[:session] == %{role: :server}
    end

    test "ignores calls when router missing" do
      state = Connection.new()
      frame = Frame.new(:call, %{msg_id: "2", route: :flush})

      assert {:noreply, ^state} = Connection.handle_frame(frame, state)
    end
  end

  defp new_state do
    Connection.new(router: ClientRouter, session: %{role: :server})
  end
end
