defmodule RpcEx.Test.Integration.ServerRouter do
  use RpcEx.Router

  middleware RpcEx.Test.Middlewares.Trace, tag: :server

  call :ping do
    _ = context
    _ = opts
    {:ok, %{pong: args[:ping]}}
  end

  call :server_to_client do
    _ = context
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:server_call, args})
    {:ok, :ok}
  end

  cast :notify do
    _ = context
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:server_cast, args})
    {:notify, %{event: :server_notify, payload: args}}
  end
end
