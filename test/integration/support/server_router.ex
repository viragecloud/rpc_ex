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

  stream :simple_stream do
    _ = context
    _ = opts
    count = args[:count] || 5
    if count > 0, do: 1..count, else: []
  end

  stream :range_stream do
    _ = context
    _ = opts
    start = args[:start] || 1
    stop = args[:stop] || 10
    start..stop
  end

  stream :lazy_stream do
    _ = context
    _ = opts
    count = args[:count] || 10
    Stream.iterate(1, &(&1 + 1)) |> Stream.take(count)
  end

  stream :error_stream do
    _ = context
    _ = opts
    _ = args

    Stream.resource(
      fn -> 0 end,
      fn
        3 -> raise "Stream error at chunk 3"
        n when n < 5 -> {[n], n + 1}
        _ -> {:halt, nil}
      end,
      fn _ -> :ok end
    )
  end
end
