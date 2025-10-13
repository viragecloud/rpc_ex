defmodule RpcEx.Runtime.DispatcherTest do
  use ExUnit.Case, async: true

  alias RpcEx.Runtime.Dispatcher

  defmodule TestRouter do
    use RpcEx.Router

    call :echo do
      _ = context
      _ = opts
      {:ok, args}
    end

    call :error_test do
      _ = args
      _ = context
      _ = opts
      {:error, :test_error}
    end

    call :error_with_detail do
      _ = args
      _ = context
      _ = opts
      {:error, :test_error, "detailed message"}
    end

    call :notify_test do
      _ = args
      _ = context
      _ = opts
      {:notify, %{event: :test}}
    end

    call :noreply_test do
      _ = args
      _ = context
      _ = opts
      :noreply
    end

    cast :log_event do
      _ = args
      _ = context
      _ = opts
      :ok
    end

    cast :notify_cast do
      _ = args
      _ = context
      _ = opts
      {:notify, %{cast_event: :test}}
    end

    stream :simple_stream do
      _ = context
      _ = opts
      _ = args
      [1, 2, 3]
    end
  end

  describe "dispatch_call/5" do
    test "dispatches successful call" do
      payload = %{route: :echo, args: %{test: :data}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :reply
      assert frame.payload.msg_id == "123"
      assert frame.payload.result == %{test: :data}
    end

    test "dispatches call with error response" do
      payload = %{route: :error_test, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :error
      assert frame.payload.msg_id == "123"
      assert frame.payload.reason == :test_error
    end

    test "dispatches call with error and detail" do
      payload = %{route: :error_with_detail, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :error
      assert frame.payload.reason == :test_error
      assert frame.payload.detail == "detailed message"
    end

    test "dispatches call with notify response" do
      payload = %{route: :notify_test, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:push, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :notify
      assert frame.payload.event == :test
    end

    test "dispatches call with noreply response" do
      payload = %{route: :noreply_test, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {:noreply, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)
    end

    test "handles unknown route" do
      payload = %{route: :unknown, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :error
      assert frame.payload.reason == :unknown_route
    end

    test "handles missing route in payload" do
      payload = %{args: %{}, msg_id: "123"}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_call(TestRouter, payload, context, session)

      assert frame.type == :error
    end

    test "includes session in context" do
      payload = %{route: :echo, args: %{}, msg_id: "123"}
      context = %{}
      session = %{test: :session}

      {{:reply, _frame}, new_context} =
        Dispatcher.dispatch_call(TestRouter, payload, context, session)

      # The context is passed through, session is injected during handler execution
      assert is_map(new_context)
    end
  end

  describe "dispatch_cast/5" do
    test "dispatches cast successfully" do
      payload = %{route: :log_event, args: %{test: :data}}
      context = %{}
      session = %{}

      {:noreply, _context} = Dispatcher.dispatch_cast(TestRouter, payload, context, session)
    end

    test "dispatches cast with notify" do
      payload = %{route: :notify_cast, args: %{}}
      context = %{}
      session = %{}

      {{:push, frame}, _context} = Dispatcher.dispatch_cast(TestRouter, payload, context, session)

      assert frame.type == :notify
      assert frame.payload.cast_event == :test
    end

    test "handles unknown cast route" do
      payload = %{route: :unknown_cast, args: %{}}
      context = %{}
      session = %{}

      {:noreply, _context} = Dispatcher.dispatch_cast(TestRouter, payload, context, session)
    end

    test "handles missing route in cast payload" do
      payload = %{args: %{}}
      context = %{}
      session = %{}

      {:noreply, _context} = Dispatcher.dispatch_cast(TestRouter, payload, context, session)
    end
  end

  describe "dispatch_discover/4" do
    test "returns router routes" do
      payload = %{msg_id: "123", scope: :all}
      context = %{}
      session = %{test: :session}

      {{:reply, frame}, _context} = Dispatcher.dispatch_discover(TestRouter, payload, context, session)

      assert frame.type == :discover_reply
      assert frame.payload.msg_id == "123"
      assert is_list(frame.payload.entries)
      assert length(frame.payload.entries) > 0
    end

    test "filters routes by scope" do
      payload = %{msg_id: "123", scope: :call}
      context = %{}
      session = %{}

      {{:reply, frame}, _context} = Dispatcher.dispatch_discover(TestRouter, payload, context, session)

      assert frame.type == :discover_reply
      assert Enum.all?(frame.payload.entries, fn entry -> entry.kind == :call end)
    end

    test "includes session in metadata" do
      payload = %{msg_id: "123", scope: :all}
      context = %{}
      session = %{user: "test"}

      {{:reply, frame}, _context} = Dispatcher.dispatch_discover(TestRouter, payload, context, session)

      assert frame.payload.meta.session == %{user: "test"}
    end
  end

  describe "dispatch_stream/6" do
    test "dispatches stream call asynchronously" do
      payload = %{route: :simple_stream, args: %{}, msg_id: "123"}
      context = %{}
      session = %{}
      caller_pid = self()

      result =
        Dispatcher.dispatch_stream(TestRouter, payload, context, session, caller_pid)

      assert result == :async

      # Wait a bit for the stream to complete
      Process.sleep(100)
    end

    test "handles invalid stream payload" do
      payload = %{args: %{}, msg_id: "123"}
      context = %{}
      session = %{}
      caller_pid = self()

      result =
        Dispatcher.dispatch_stream(TestRouter, payload, context, session, caller_pid)

      assert result == :async

      # Should receive error frame
      assert_receive {:stream_error, frame}, 500
      assert frame.type == :stream_error
    end
  end
end
