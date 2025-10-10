defmodule RpcEx.Test.Integration.ServerRouter do
  @moduledoc false
  use RpcEx.Router

  middleware RpcEx.Test.Middlewares.Trace, tag: :server

  call :ping do
    _ = context
    _ = opts
    {:ok, %{pong: args[:ping]}}
  end

  call :server_to_client do
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:server_call, args})

    # Server calls back to client's :server_to_client handler
    peer = context.peer
    {:ok, result, _meta} = RpcEx.Peer.call(peer, :server_to_client, args: args)

    {:ok, result}
  end

  cast :notify do
    _ = context
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:server_cast, args})
    {:notify, %{event: :server_notify, payload: args}}
  end

  call :slow_add do
    _ = context
    _ = opts
    delay = args[:delay] || 100
    Process.sleep(delay)
    {:ok, %{sum: args[:a] + args[:b], delay: delay}}
  end
end
