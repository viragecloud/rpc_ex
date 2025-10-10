defmodule RpcEx.Server.ConnectionTest do
  use ExUnit.Case, async: true

  alias RpcEx.Protocol.Frame
  alias RpcEx.Server.Connection

  defmodule Router do
    use RpcEx.Router

    middleware RpcEx.Test.Middlewares.Trace, tag: :server

    call :echo do
      {:ok, %{args: args, context: context, opts: opts}}
    end

    call :fail do
      _ = args
      _ = context
      _ = opts
      {:error, :boom, %{info: :failure}}
    end

    cast :notify do
      _ = args
      _ = context
      _ = opts
      {:notify, %{event: :ping, payload: args}}
    end
  end

  setup do
    routes = Router.__rpc_routes__()
    refute Enum.empty?(routes)

    assert Enum.any?(routes, fn route ->
             route.name == :echo and
               route.middlewares == [{RpcEx.Test.Middlewares.Trace, [tag: :server]}]
           end)

    state = Connection.new(router: Router, session: %{role: :client})
    %{state: state}
  end

  describe "handle_frame/2 for calls" do
    test "returns reply frame on successful call", %{state: state} do
      frame =
        Frame.new(:call, %{
          msg_id: "1",
          route: :echo,
          args: %{message: "hi"},
          timeout_ms: 1000,
          meta: %{trace_id: "abc"}
        })

      # Calls now execute asynchronously
      {:async, _new_state} = Connection.handle_frame(frame, state)

      # Wait for the async result
      assert_receive {:handler_result, :call, action, _ctx}, 1000

      assert {:reply, reply} = action
      assert %Frame{type: :reply, payload: payload} = reply
      assert payload.msg_id == "1"
      assert %{args: %{message: "hi", trace: :server}} = payload.result
      assert payload.meta == %{trace_id: "abc"}
    end

    test "returns error frame when handler errors", %{state: state} do
      frame = Frame.new(:call, %{msg_id: "2", route: :fail})

      {:async, _} = Connection.handle_frame(frame, state)

      assert_receive {:handler_result, :call, action, _ctx}, 1000

      assert {:reply, reply} = action
      assert %Frame{type: :error, payload: payload} = reply
      assert payload.msg_id == "2"
      assert payload.reason == :boom
      assert payload.detail == %{info: :failure}
    end

    test "returns error frame when route missing", %{state: state} do
      frame = Frame.new(:call, %{msg_id: "3", route: :missing})

      {:async, _} = Connection.handle_frame(frame, state)

      assert_receive {:handler_result, :call, action, _ctx}, 1000

      assert {:reply, reply} = action
      assert %Frame{type: :error, payload: payload} = reply
      assert payload.msg_id == "3"
      assert payload.reason == :unknown_route
    end
  end

  describe "handle_frame/2 for casts" do
    test "pushes notify frame when handler returns notify", %{state: state} do
      frame = Frame.new(:cast, %{route: :notify, args: %{value: 1}})

      {:push, notify, new_state} = Connection.handle_frame(frame, state)

      assert %Frame{type: :notify, payload: payload} = notify
      assert payload.route == :notify
      assert payload.event == :ping
      assert payload.payload == %{value: 1, trace: :server}
      assert new_state.context[:trace] == :server
    end

    test "ignores unknown cast routes", %{state: state} do
      frame = Frame.new(:cast, %{route: :unknown})

      assert {:noreply, ^state} = Connection.handle_frame(frame, state)
    end
  end

  describe "handle_frame/2 for discovery" do
    test "returns discover_reply frame", %{state: state} do
      frame = Frame.new(:discover, %{msg_id: "disc"})

      {:reply, reply, _} = Connection.handle_frame(frame, state)

      assert %Frame{type: :discover_reply, payload: payload} = reply
      assert payload.msg_id == "disc"
      assert Enum.any?(payload.entries, fn entry -> entry.route == :echo end)
    end
  end
end
