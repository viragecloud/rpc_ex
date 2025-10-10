defmodule RpcEx.PeerTest do
  use ExUnit.Case, async: true

  alias RpcEx.Peer
  alias RpcEx.Protocol.Frame

  describe "new/1" do
    test "creates peer with handler_pid" do
      peer = Peer.new(handler_pid: self())
      assert peer.handler_pid == self()
      assert peer.timeout == 5_000
    end

    test "creates peer with custom timeout" do
      peer = Peer.new(handler_pid: self(), timeout: 10_000)
      assert peer.handler_pid == self()
      assert peer.timeout == 10_000
    end
  end

  describe "call/3" do
    test "sends peer_call message and awaits response" do
      peer = Peer.new(handler_pid: self())

      task =
        Task.async(fn ->
          Peer.call(peer, :test_route, args: %{foo: :bar}, timeout: 100)
        end)

      # Should receive peer_call message
      assert_receive {:peer_call, ref, %Frame{} = frame, from_pid}, 100

      assert frame.type == :call
      assert frame.payload.route == :test_route
      assert frame.payload.args == %{foo: :bar}
      assert is_binary(frame.payload.msg_id)

      # Send reply
      send(from_pid, {:peer_reply, ref, {:ok, %{result: :success}, %{}}})

      # Task should complete
      assert {:ok, %{result: :success}, %{}} = Task.await(task)
    end

    test "returns error response" do
      peer = Peer.new(handler_pid: self())

      task =
        Task.async(fn ->
          Peer.call(peer, :test_route, args: %{}, timeout: 100)
        end)

      assert_receive {:peer_call, ref, _frame, from_pid}, 100
      send(from_pid, {:peer_reply, ref, {:error, :not_found}})

      assert {:error, :not_found} = Task.await(task)
    end

    test "times out if no response received" do
      peer = Peer.new(handler_pid: self(), timeout: 50)

      assert {:error, :timeout} = Peer.call(peer, :test_route, args: %{})

      # Should still receive the message
      assert_receive {:peer_call, _ref, _frame, _from_pid}, 100
    end

    test "uses custom timeout from options" do
      peer = Peer.new(handler_pid: self())

      task =
        Task.async(fn ->
          Peer.call(peer, :test_route, args: %{}, timeout: 50)
        end)

      # Don't respond - should timeout
      assert {:error, :timeout} = Task.await(task, 200)
    end

    test "includes meta in call payload" do
      peer = Peer.new(handler_pid: self())

      task =
        Task.async(fn ->
          Peer.call(peer, :test, args: %{}, meta: %{request_id: "123"})
        end)

      assert_receive {:peer_call, _ref, frame, _from_pid}, 100
      assert frame.payload.meta == %{request_id: "123"}

      # Clean up
      Process.exit(task.pid, :kill)
    end
  end

  describe "cast/3" do
    test "sends peer_cast message without awaiting response" do
      peer = Peer.new(handler_pid: self())

      assert :ok = Peer.cast(peer, :notify, args: %{event: :test})

      assert_receive {:peer_cast, %Frame{} = frame}, 100
      assert frame.type == :cast
      assert frame.payload.route == :notify
      assert frame.payload.args == %{event: :test}
    end

    test "includes meta in cast payload" do
      peer = Peer.new(handler_pid: self())

      assert :ok = Peer.cast(peer, :notify, args: %{}, meta: %{trace_id: "abc"})

      assert_receive {:peer_cast, frame}, 100
      assert frame.payload.meta == %{trace_id: "abc"}
    end

    test "returns immediately without waiting" do
      peer = Peer.new(handler_pid: self())

      # Cast should return immediately
      start_time = System.monotonic_time(:millisecond)
      assert :ok = Peer.cast(peer, :notify, args: %{})
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete in < 10ms (not wait for any response)
      assert elapsed < 10
    end
  end
end
