defmodule RpcEx.Test.Integration.ClientRouter do
  use RpcEx.Router

  middleware RpcEx.Test.Middlewares.Trace, tag: :client

  call :server_to_client do
    _ = context
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:client_call, args})
    {:reply, :client_ack}
  end

  cast :server_cast do
    _ = context
    _ = opts
    RpcEx.Test.Integration.Tracker.record({:client_cast, args})
    :noreply
  end
end
