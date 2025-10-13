defmodule RpcEx.Server.Connection do
  @moduledoc """
  Connection state and helpers for handling inbound frames on the server side.

  The WebSocket handler will instantiate this module and forward decoded
  `RpcEx.Protocol.Frame` structs, receiving instructions on whether to reply,
  push additional frames, or simply continue without response.
  """

  alias RpcEx.Protocol.Frame
  alias RpcEx.Runtime.Dispatcher

  @type t :: %__MODULE__{
          router: module(),
          context: map(),
          session: map()
        }

  defstruct router: nil, context: %{}, session: %{}

  @doc """
  Builds a new connection state.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      router: Keyword.fetch!(opts, :router),
      context: Keyword.get(opts, :context, %{}),
      session: Keyword.get(opts, :session, %{})
    }
  end

  @doc """
  Handles an inbound frame, returning an action tuple suitable for the WebSocket handler.
  """
  @spec handle_frame(Frame.t(), t()) ::
          {:reply, Frame.t(), t()}
          | {:push, Frame.t(), t()}
          | {:noreply, t()}
          | {:async, t()}
  def handle_frame(%Frame{type: :call, payload: %{route: route} = payload}, state) do
    # Check if this is a stream route
    case lookup_route_kind(state.router, route) do
      {:ok, :stream} ->
        # Handle as stream
        caller = self()
        Dispatcher.dispatch_stream(state.router, payload, state.context, state.session, caller)
        {:async, state}

      _ ->
        # Handle as regular call (existing behavior)
        handle_regular_call(payload, state)
    end
  end

  def handle_frame(%Frame{type: :cast, payload: payload}, state) do
    {action, new_ctx} =
      Dispatcher.dispatch_cast(state.router, payload, state.context, state.session)

    wrap(action, %{state | context: new_ctx})
  end

  def handle_frame(%Frame{type: :discover, payload: payload}, state) do
    {action, new_ctx} =
      Dispatcher.dispatch_discover(state.router, payload, state.context, state.session)

    wrap(action, %{state | context: new_ctx})
  end

  def handle_frame(_frame, state), do: {:noreply, state}

  defp handle_regular_call(payload, state) do
    # Spawn handler in a task to avoid blocking the WebSocket process
    # This allows bidirectional RPC where handlers can call back to the peer
    caller = self()

    Task.start(fn ->
      {action, new_ctx} =
        Dispatcher.dispatch_call(state.router, payload, state.context, state.session)

      send(caller, {:handler_result, :call, action, new_ctx})
    end)

    {:async, state}
  end

  defp lookup_route_kind(router, route_name) do
    try do
      router.__rpc_routes__()
      |> Enum.find(fn %RpcEx.Router.Route{name: name} -> name == route_name end)
      |> case do
        %RpcEx.Router.Route{kind: kind} -> {:ok, kind}
        nil -> {:error, :not_found}
      end
    rescue
      _ -> {:error, :not_found}
    end
  end

  defp wrap({:reply, frame}, state), do: {:reply, frame, state}
  defp wrap({:push, frame}, state), do: {:push, frame, state}
  defp wrap(:noreply, state), do: {:noreply, state}
end
