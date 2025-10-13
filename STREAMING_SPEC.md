# RpcEx Streaming Support Specification

## Overview

Add native streaming support to RpcEx to enable server-to-client streaming for use cases like:
- Log streaming (container logs, build output)
- Large result sets (paginated data)
- Real-time updates (metrics, events)
- File transfers

## Requirements

### 1. Protocol Extension

Add new frame types to the RpcEx protocol:

```elixir
# Existing frames
:call     # Client -> Server: Request with expected response
:reply    # Server -> Client: Single response to :call
:cast     # Client -> Server: Fire-and-forget
:error    # Server -> Client: Error response

# New frames for streaming
:stream   # Server -> Client: Stream data chunk
:stream_end  # Server -> Client: Stream completed successfully
:stream_error # Server -> Client: Stream failed with error
```

### 2. Router DSL Extension

Add `stream` as a first-class action alongside `call` and `cast`:

```elixir
defmodule MyRouter do
  use RpcEx.Router

  # Existing: Single request/response
  call :get_user do
    {:ok, %{id: 1, name: "Alice"}}
  end

  # Existing: Fire-and-forget
  cast :log_event do
    Logger.info("Event: #{inspect(args)}")
    :ok
  end

  # NEW: Streaming action
  stream :container_logs do
    # Return any Enumerable (Stream, List, etc.)
    container_id = args[:container_id]
    File.stream!("/var/log/container-#{container_id}.log")
  end

  # NEW: Streaming with lazy generation
  stream :large_dataset do
    Stream.resource(
      fn -> Database.connect() end,
      fn conn ->
        case Database.fetch_next_batch(conn, 100) do
          {:ok, rows} when rows != [] -> {rows, conn}
          _ -> {:halt, conn}
        end
      end,
      fn conn -> Database.disconnect(conn) end
    )
  end

  # NEW: Streaming with transformation
  stream :metrics_feed do
    Stream.interval(1000)
    |> Stream.map(fn _ -> collect_metrics() end)
  end
end
```

**Key Points:**
- `stream` blocks must return an `Enumerable` (Stream, List, etc.)
- The enumerable is processed lazily - items are sent as they're generated
- Middleware runs before enumeration starts (for auth, validation, etc.)
- The block has access to `args` and `context` like `call` and `cast`

### 3. Client API

Add streaming methods to `RpcEx.Client`:

```elixir
# Existing
RpcEx.Client.call(client, :method, args: %{})
# => {:ok, result, meta}

# NEW: Stream consumption
RpcEx.Client.stream(client, :method, args: %{})
# => {:ok, stream, meta}
# where stream is an Elixir Stream that can be enumerated

# Usage example
{:ok, stream, _meta} = RpcEx.Client.stream(client, :container_logs, args: %{container_id: "abc"})

stream
|> Stream.each(&IO.puts/1)
|> Stream.run()

# Or collect all
logs = Enum.to_list(stream)
```

### 4. Frame Format

#### `:stream` Frame
```elixir
%{
  type: :stream,
  id: "request-correlation-id",  # Same ID as original :call
  chunk: <data>,                  # The chunk of data
  meta: %{
    sequence: 1,                  # Sequence number (optional)
    total: nil                    # Total chunks if known (optional)
  }
}
```

#### `:stream_end` Frame
```elixir
%{
  type: :stream_end,
  id: "request-correlation-id",
  meta: %{
    total_chunks: 42,
    bytes_sent: 1024000
  }
}
```

#### `:stream_error` Frame
```elixir
%{
  type: :stream_error,
  id: "request-correlation-id",
  error: "Error message",
  code: :internal_error
}
```

### 5. Server-Side Implementation

When a `stream` route is called:

1. Router dispatches to the `stream` handler
2. Handler returns an `Enumerable`
3. Server spawns a supervised task to process the enumerable
4. For each item in the enumerable:
   - Send `:stream` frame to client
   - Optionally apply backpressure if client can't keep up
5. When enumerable completes:
   - Send `:stream_end` frame
6. If enumerable raises/errors:
   - Send `:stream_error` frame

```elixir
# Pseudo-code in RpcEx.Router
defmacro stream(route_name, do: block) do
  quote do
    @routes Map.put(@routes, unquote(route_name), %{
      kind: :stream,
      handler: fn args, context ->
        # Execute handler block
        unquote(block)
      end
    })
  end
end

# Pseudo-code in RpcEx.Server for handling stream routes
def execute_stream_handler(handler, args, context, request_id, conn) do
  Task.Supervisor.start_child(StreamSupervisor, fn ->
    try do
      enumerable = handler.(args, context)

      enumerable
      |> Stream.with_index(1)
      |> Enum.each(fn {chunk, sequence} ->
        frame = %{
          type: :stream,
          id: request_id,
          chunk: chunk,
          meta: %{sequence: sequence}
        }
        send_frame(conn, frame)

        # Optional: Check for cancellation
        check_cancellation(request_id)
      end)

      send_frame(conn, %{type: :stream_end, id: request_id, meta: %{}})
    rescue
      error ->
        send_frame(conn, %{
          type: :stream_error,
          id: request_id,
          error: Exception.message(error),
          code: :internal_error
        })
    catch
      :exit, reason ->
        send_frame(conn, %{
          type: :stream_error,
          id: request_id,
          error: "Stream process exited: #{inspect(reason)}",
          code: :internal_error
        })
    end
  end)

  :ok
end
```

### 6. Client-Side Implementation

When `RpcEx.Client.stream/3` is called:

1. Send `:call` frame as usual
2. Store correlation ID in client state with a stream accumulator
3. As `:stream` frames arrive:
   - Buffer them or deliver to Stream consumer
4. When `:stream_end` arrives:
   - Complete the Stream
5. When `:stream_error` arrives:
   - Raise error in Stream

The returned Stream should be lazy and pull-based:

```elixir
def stream(client, method, opts) do
  request_id = generate_id()

  # Send the call frame
  send_call(client, method, request_id, opts)

  # Return a Stream that pulls from a GenServer mailbox
  stream = Stream.resource(
    fn -> {client, request_id, :active} end,
    fn {client, req_id, :active} = acc ->
      case wait_for_stream_chunk(client, req_id) do
        {:chunk, data} -> {[data], acc}
        :stream_end -> {:halt, acc}
        {:error, reason} -> raise "Stream error: #{reason}"
      end

      {client, req_id, :done} -> {:halt, {client, req_id, :done}}
    end,
    fn {client, req_id, _} -> cleanup_stream(client, req_id) end
  )

  {:ok, stream, %{}}
end
```

### 7. Backpressure (Optional but Recommended)

Implement flow control to prevent overwhelming slow clients:

```elixir
# Server tracks pending stream chunks per connection
# If buffer grows too large, pause enumeration
# Resume when client catches up
```

Could use simple windowing:
- Server sends N chunks
- Waits for `:stream_ack` from client
- Sends next N chunks

### 8. Timeout Handling

Streaming should respect timeouts:

```elixir
# Client-side
RpcEx.Client.stream(client, :logs, args: %{}, timeout: 30_000)

# If no :stream or :stream_end frame received within timeout:
# - Stream raises timeout error
# - Client sends cancellation frame to server (optional)
```

### 9. Cancellation (Optional)

Allow clients to cancel active streams:

```elixir
# New frame type
:stream_cancel  # Client -> Server: Cancel active stream

# Usage
{:ok, stream, _meta} = RpcEx.Client.stream(client, :long_operation, args: %{})

# Later, if needed:
RpcEx.Client.cancel_stream(client, stream_id)
```

### 10. Memory Safety

**Critical**: Streams must not buffer entire result in memory

- Server should process enumerable lazily, sending chunks as generated
- Client should provide lazy Stream, not collect all chunks upfront
- Both sides should have configurable max buffer sizes

### 11. Testing Requirements

RpcEx should include tests for:

```elixir
# Basic streaming
test "streams data from server to client"
test "stream completes with :stream_end"
test "stream handles errors with :stream_error"

# Edge cases
test "empty stream sends :stream_end immediately"
test "large stream (1M+ items) uses constant memory"
test "slow consumer doesn't block server"
test "stream timeout cancels operation"
test "client disconnect during stream stops enumeration"

# Concurrent streams
test "multiple concurrent streams per connection"
test "streams don't interfere with regular calls"
```

## Implementation Checklist

### RpcEx.Protocol
- [ ] Add `:stream`, `:stream_end`, `:stream_error` frame types
- [ ] Update frame encoding/decoding for new types
- [ ] Add frame validation

### RpcEx.Server
- [ ] Detect `{:stream, enumerable}` handler returns
- [ ] Spawn supervised task to process enumerable
- [ ] Send stream frames as data arrives
- [ ] Handle enumerable errors gracefully
- [ ] Implement backpressure mechanism

### RpcEx.Client
- [ ] Add `stream/3` function
- [ ] Implement lazy Stream that pulls from mailbox
- [ ] Handle `:stream`, `:stream_end`, `:stream_error` frames
- [ ] Add timeout support for streams
- [ ] Track active streams in client state

### RpcEx.Router
- [ ] Add `stream` macro alongside `call` and `cast`
- [ ] Register stream routes with `kind: :stream`
- [ ] Execute stream handlers in supervised tasks
- [ ] Handle enumerable results

### Tests
- [ ] Unit tests for frame encoding/decoding
- [ ] Integration tests for server streaming
- [ ] Integration tests for client consumption
- [ ] Memory leak tests
- [ ] Concurrent stream tests
- [ ] Error handling tests

## Usage Examples

### Server: Log Streaming

```elixir
defmodule AgentRouter do
  use RpcEx.Router

  # Simple file streaming
  stream :container_logs do
    container_id = args[:container_id]
    File.stream!("/var/log/container-#{container_id}.log")
  end

  # Live tailing (follow mode)
  stream :container_logs_live do
    container_id = args[:container_id]

    Stream.resource(
      fn -> Docker.attach_logs(container_id) end,
      fn handle ->
        case Docker.read_log_line(handle) do
          {:ok, line} -> {[line], handle}
          :eof -> {:halt, handle}
        end
      end,
      fn handle -> Docker.detach_logs(handle) end
    )
  end

  # Streaming with validation
  middleware VirageRpc.Middleware.SchemaValidation,
    schemas: %{
      paginated_logs: [
        container_id: [type: :string, required: true],
        since: [type: :string],
        limit: [type: :integer, default: 1000]
      ]
    }

  stream :paginated_logs do
    container_id = args[:container_id]
    since = args[:since]
    limit = args[:limit]

    fetch_logs(container_id, since: since)
    |> Stream.take(limit)
  end
end
```

### Client: Consuming Stream

```elixir
{:ok, client} = RpcEx.Client.start_link(url: "ws://agent:4000")

{:ok, stream, _meta} = RpcEx.Client.stream(client, :container_logs,
  args: %{container_id: "abc123", follow: true},
  timeout: 60_000
)

# Process stream lazily
stream
|> Stream.take_while(fn line -> not String.contains?(line, "DONE") end)
|> Stream.each(&IO.puts/1)
|> Stream.run()

# Or collect (careful with memory!)
logs = Enum.take(stream, 1000)
```

### VirageRpc Wrapper

```elixir
# In VirageRpc module
@spec stream(client(), method(), params(), keyword()) ::
  {:ok, Enumerable.t()} | {:error, term()}
def stream(client, method, params \\ %{}, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 30_000)

  case RpcEx.Client.stream(client, method, args: params, timeout: timeout) do
    {:ok, stream, _meta} -> {:ok, stream}
    {:error, reason} -> {:error, reason}
  end
end
```

## Performance Requirements

- **Latency**: First chunk should arrive within call timeout
- **Throughput**: Should handle 10K+ small chunks/second
- **Memory**: Server and client memory usage should be constant regardless of stream size
- **Concurrency**: Should support 100+ concurrent streams per connection

## Backward Compatibility

- Existing `:call` and `:cast` behavior unchanged
- Old clients/servers that don't understand `:stream` frames will error gracefully
- Version negotiation in handshake could advertise streaming support

## Future Enhancements

- **Bidirectional streaming**: Both client and server stream data
- **Stream compression**: Compress chunks before sending
- **Stream multiplexing**: Multiple streams over single connection with priorities
- **Flow control**: More sophisticated backpressure mechanisms

