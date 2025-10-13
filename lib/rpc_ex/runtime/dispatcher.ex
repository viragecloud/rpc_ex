defmodule RpcEx.Runtime.Dispatcher do
  @moduledoc """
  Shared helpers for delegating protocol frames through the router executor.
  """

  require Logger

  alias RpcEx.Protocol.Frame
  alias RpcEx.Reflection
  alias RpcEx.Router.Executor

  @type context :: map()
  @type session :: map()

  @type dispatch_action ::
          {:reply, Frame.t()}
          | {:push, Frame.t()}
          | :noreply

  @type dispatch_result :: {dispatch_action(), context()}

  @doc """
  Handles an inbound `:call` frame.
  """
  @spec dispatch_call(
          module(),
          map(),
          context(),
          session(),
          keyword()
        ) :: dispatch_result()
  def dispatch_call(router, payload, context, session, opts \\ []) do
    case fetch_route(payload) do
      {:ok, route} ->
        args = Map.get(payload, :args, %{})
        msg_id = Map.get(payload, :msg_id)
        dispatch_opts = build_call_opts(payload, opts)
        base_context = build_context(context, session, Map.get(payload, :meta))

        case Executor.dispatch(router, :call, route, args, base_context, dispatch_opts) do
          {:ok, result, new_ctx} ->
            respond_call(route, msg_id, result, new_ctx)

          {:halt, result, new_ctx} ->
            respond_call(route, msg_id, result, new_ctx)

          {:error, {:unknown_route, _}} ->
            {error_action(:call, route, msg_id), context}
        end

      {:error, reason} ->
        log_invalid_payload(:call, reason, payload)
        {error_action(:call, nil, Map.get(payload, :msg_id), reason), context}
    end
  end

  @doc """
  Handles an inbound `:cast` frame.
  """
  @spec dispatch_cast(
          module(),
          map(),
          context(),
          session(),
          keyword()
        ) :: dispatch_result()
  def dispatch_cast(router, payload, context, session, opts \\ []) do
    case fetch_route(payload) do
      {:ok, route} ->
        args = Map.get(payload, :args, %{})
        dispatch_opts = build_cast_opts(payload, opts)
        base_context = build_context(context, session, Map.get(payload, :meta))

        case Executor.dispatch(router, :cast, route, args, base_context, dispatch_opts) do
          {:ok, result, new_ctx} ->
            respond_cast(route, result, new_ctx)

          {:halt, result, new_ctx} ->
            respond_cast(route, result, new_ctx)

          {:error, {:unknown_route, _}} ->
            {log_unknown_cast(route), context}
        end

      {:error, reason} ->
        log_invalid_payload(:cast, reason, payload)
        {:noreply, context}
    end
  end

  @doc """
  Handles an inbound `:discover` frame by returning router metadata.
  """
  @spec dispatch_discover(module(), map(), context(), session()) :: dispatch_result()
  def dispatch_discover(router, payload, context, session) do
    msg_id = Map.get(payload, :msg_id)
    scope = Map.get(payload, :scope, :all)
    entries = routes_for_scope(router, scope)

    reply =
      Frame.new(:discover_reply, %{
        msg_id: msg_id,
        entries: entries,
        meta: %{session: session}
      })

    {{:reply, reply}, context}
  end

  @doc """
  Handles an inbound `:stream` call by initiating streaming execution.

  Returns `:async` to indicate that the handler will be processed asynchronously.
  The caller is responsible for spawning a task to process the stream.
  """
  @spec dispatch_stream(
          module(),
          map(),
          context(),
          session(),
          pid(),
          keyword()
        ) :: :async
  def dispatch_stream(router, payload, context, session, caller_pid, opts \\ []) do
    case fetch_route(payload) do
      {:ok, route} ->
        args = Map.get(payload, :args, %{})
        msg_id = Map.get(payload, :msg_id)
        dispatch_opts = build_call_opts(payload, opts)
        base_context = build_context(context, session, Map.get(payload, :meta))

        # Spawn a task to handle the streaming
        Task.start(fn ->
          execute_stream_handler(router, route, msg_id, args, base_context, dispatch_opts, caller_pid)
        end)

        :async

      {:error, reason} ->
        log_invalid_payload(:stream, reason, payload)
        msg_id = Map.get(payload, :msg_id)
        error_frame = build_stream_error_frame(msg_id, reason, "Invalid payload")
        send(caller_pid, {:stream_error, error_frame})
        :async
    end
  end

  defp execute_stream_handler(router, route, msg_id, args, context, opts, caller_pid) do
    try do
      case Executor.dispatch(router, :stream, route, args, context, opts) do
        {:ok, enumerable, _new_ctx} ->
          stream_enumerable(enumerable, msg_id, caller_pid)

        {:halt, enumerable, _new_ctx} ->
          stream_enumerable(enumerable, msg_id, caller_pid)

        {:error, {:unknown_route, _}} ->
          error_frame = build_stream_error_frame(msg_id, :unknown_route, "Unknown route: #{route}")
          send(caller_pid, {:stream_error, error_frame})
      end
    rescue
      exception ->
        error_frame = build_stream_error_frame(msg_id, :internal_error, Exception.message(exception))
        send(caller_pid, {:stream_error, error_frame})
    catch
      kind, reason ->
        error_frame = build_stream_error_frame(msg_id, :internal_error, "#{kind}: #{inspect(reason)}")
        send(caller_pid, {:stream_error, error_frame})
    end
  end

  defp stream_enumerable(enumerable, msg_id, caller_pid) do
    try do
      enumerable
      |> Stream.with_index(1)
      |> Enum.each(fn {chunk, sequence} ->
        frame = Frame.new(:stream, %{
          msg_id: msg_id,
          chunk: chunk,
          meta: %{sequence: sequence}
        })
        send(caller_pid, {:stream_chunk, frame})
      end)

      # Send stream_end when complete
      end_frame = Frame.new(:stream_end, %{
        msg_id: msg_id,
        meta: %{}
      })
      send(caller_pid, {:stream_end, end_frame})
    rescue
      exception ->
        error_frame = build_stream_error_frame(msg_id, :stream_error, Exception.message(exception))
        send(caller_pid, {:stream_error, error_frame})
    catch
      kind, reason ->
        error_frame = build_stream_error_frame(msg_id, :stream_error, "#{kind}: #{inspect(reason)}")
        send(caller_pid, {:stream_error, error_frame})
    end
  end

  defp build_stream_error_frame(msg_id, code, message) do
    Frame.new(:stream_error, %{
      msg_id: msg_id,
      error: message,
      code: code
    })
  end

  defp respond_call(route, msg_id, result, context) do
    case normalize_call_result(result) do
      {:reply, value, meta} ->
        payload =
          %{
            msg_id: msg_id,
            route: route,
            result: value,
            meta: meta || Map.get(context, :meta, %{})
          }
          |> compact_map()

        {{:reply, Frame.new(:reply, payload)}, context}

      {:error, reason, detail} ->
        payload =
          %{
            msg_id: msg_id,
            route: route,
            reason: reason,
            detail: detail
          }
          |> compact_map()

        {{:reply, Frame.new(:error, payload)}, context}

      {:notify, payload_map} ->
        payload =
          payload_map
          |> mapify()
          |> Map.put_new(:route, route)

        {{:push, Frame.new(:notify, payload)}, context}

      :noreply ->
        {:noreply, context}
    end
  end

  defp respond_cast(route, result, context) do
    case normalize_cast_result(result) do
      {:notify, payload_map} ->
        payload =
          payload_map
          |> mapify()
          |> Map.put_new(:route, route)

        {{:push, Frame.new(:notify, payload)}, context}

      {:error, reason, detail} ->
        payload =
          %{
            route: route,
            reason: reason,
            detail: detail
          }
          |> compact_map()

        {{:push, Frame.new(:error, payload)}, context}

      :noreply ->
        {:noreply, context}
    end
  end

  defp fetch_route(%{route: route}) when is_atom(route) or is_binary(route), do: {:ok, route}
  defp fetch_route(%{"route" => route}) when is_atom(route) or is_binary(route), do: {:ok, route}
  defp fetch_route(_), do: {:error, :missing_route}

  defp build_call_opts(payload, extra) do
    []
    |> put_opt(:timeout, Map.get(payload, :timeout_ms))
    |> put_opt(:meta, Map.get(payload, :meta))
    |> Keyword.merge(extra)
  end

  defp build_cast_opts(payload, extra) do
    []
    |> put_opt(:meta, Map.get(payload, :meta))
    |> Keyword.merge(extra)
  end

  defp build_context(context, session, nil) do
    context
    |> Map.put(:session, session)
  end

  defp build_context(context, session, meta) when is_map(meta) do
    context
    |> Map.put(:session, session)
    |> Map.put(:meta, meta)
  end

  defp build_context(context, session, _meta) do
    context
    |> Map.put(:session, session)
  end

  defp normalize_call_result({:reply, value, meta}) when is_map(meta), do: {:reply, value, meta}
  defp normalize_call_result({:reply, value, nil}), do: {:reply, value, nil}
  defp normalize_call_result({:reply, value}), do: {:reply, value, nil}
  defp normalize_call_result({:ok, value}), do: {:reply, value, nil}
  defp normalize_call_result({:error, reason, detail}), do: {:error, reason, detail}
  defp normalize_call_result({:error, reason}), do: {:error, reason, nil}
  defp normalize_call_result({:notify, payload}), do: {:notify, payload}
  defp normalize_call_result(:noreply), do: :noreply
  defp normalize_call_result(value), do: {:reply, value, nil}

  defp normalize_cast_result({:notify, payload}), do: {:notify, payload}
  defp normalize_cast_result({:error, reason, detail}), do: {:error, reason, detail}
  defp normalize_cast_result({:error, reason}), do: {:error, reason, nil}
  defp normalize_cast_result(:noreply), do: :noreply
  defp normalize_cast_result(_), do: :noreply

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp mapify(%{} = map), do: map
  defp mapify(value), do: %{data: value}

  defp log_invalid_payload(kind, reason, payload) do
    Logger.warning("invalid #{kind} payload: #{inspect(reason)} - #{inspect(payload)}")
  end

  defp log_unknown_cast(route) do
    Logger.debug("dropping cast for unknown route #{inspect(route)}")
    :noreply
  end

  defp error_action(:call, route, msg_id, reason \\ :unknown_route) do
    payload =
      %{
        msg_id: msg_id,
        route: route,
        reason: reason
      }
      |> compact_map()

    {:reply, Frame.new(:error, payload)}
  end

  defp routes_for_scope(router, :all), do: Reflection.describe(router)

  defp routes_for_scope(router, scope) do
    router
    |> Reflection.describe()
    |> Enum.filter(fn %{kind: kind} -> kind == scope end)
  end
end
