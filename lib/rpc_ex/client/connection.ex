defmodule RpcEx.Client.Connection do
  @moduledoc """
  Client-side connection helper that routes inbound frames through the router executor.

  This module mirrors the behaviour of the server connection for handling
  server-initiated RPC calls/casts once the WebSocket session is established.
  """

  alias RpcEx.Protocol.Frame
  alias RpcEx.Runtime.Dispatcher

  @type t :: %__MODULE__{
          router: module() | nil,
          context: map(),
          session: map()
        }

  defstruct router: nil, context: %{}, session: %{}

  @doc """
  Builds a new client connection state.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      router: Keyword.get(opts, :router),
      context: Keyword.get(opts, :context, %{}),
      session: Keyword.get(opts, :session, %{})
    }
  end

  @doc """
  Updates the router module used for inbound dispatch.
  """
  @spec put_router(t(), module()) :: t()
  def put_router(state, router) when is_atom(router) do
    %{state | router: router}
  end

  @doc """
  Handles an inbound frame emitted by the server.
  """
  @spec handle_frame(Frame.t(), t()) ::
          {:reply, Frame.t(), t()}
          | {:push, Frame.t(), t()}
          | {:noreply, t()}
  def handle_frame(%Frame{type: type}, state)
      when type in [:call, :cast, :discover] and is_nil(state.router) do
    {:noreply, state}
  end

  def handle_frame(%Frame{type: :call, payload: payload}, state) do
    {action, new_ctx} =
      Dispatcher.dispatch_call(state.router, payload, state.context, state.session)

    wrap(action, %{state | context: new_ctx})
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

  defp wrap({:reply, frame}, state), do: {:reply, frame, state}
  defp wrap({:push, frame}, state), do: {:push, frame, state}
  defp wrap(:noreply, state), do: {:noreply, state}
end
