defmodule RpcEx.Server.WebSocketHandler do
  @moduledoc false

  @behaviour WebSock

  alias RpcEx.Protocol.{Frame, Handshake}
  alias RpcEx.Server.Connection

  @type state :: %{
          router: module(),
          handshake_opts: keyword(),
          negotiated?: boolean(),
          connection: Connection.t() | nil,
          context: map()
        }

  @impl WebSock
  def init(opts) do
    state = %{
      router: Map.fetch!(opts, :router),
      handshake_opts: Map.get(opts, :handshake_opts, []),
      context: Map.get(opts, :context, %{}),
      negotiated?: false,
      connection: nil
    }

    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, opcode: :binary}, %{negotiated?: false} = state) do
    with {:ok, %Frame{type: :hello, payload: payload}} <- Frame.decode(data),
         {:ok, reply, new_state} <- negotiate(state, payload) do
      {:push, {:binary, Frame.encode!(reply)}, new_state}
    else
      {:ok, %Frame{} = frame} ->
        {:stop, {:error, {:unexpected_frame, frame.type}}, {1002, "unexpected_frame"}, state}

      {:error, reason} ->
        {:stop, {:error, {:handshake_failed, reason}}, {1002, reason_to_binary(reason)}, state}
    end
  end

  def handle_in({data, opcode: :binary}, %{negotiated?: true, connection: conn} = state) do
    with {:ok, frame} <- Frame.decode(data) do
      dispatch_frame(frame, state, conn)
    else
      {:error, reason} ->
        {:stop, {:error, {:invalid_frame, reason}}, {1003, reason_to_binary(reason)}, state}
    end
  end

  def handle_in({_data, opcode: :text}, state) do
    {:stop, {:error, :unsupported_opcode}, {1003, "text_frames_not_supported"}, state}
  end

  @impl WebSock
  def handle_control({_data, _opts}, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp negotiate(%{router: router} = state, payload) do
    local = Handshake.build(state.handshake_opts || [])

    case Handshake.negotiate(local, payload) do
      {:ok, session} ->
        connection =
          Connection.new(
            router: router,
            session: session,
            context: Map.get(state, :context, %{})
          )

        reply =
          Frame.new(:welcome, %{
            protocol_version: session.protocol_version,
            compression: session.compression,
            encoding: session.encoding,
            capabilities: session.local_capabilities,
            meta: session.meta
          })

        {:ok, reply, %{state | negotiated?: true, connection: connection}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_frame(frame, state, conn) do
    case Connection.handle_frame(frame, conn) do
      {:reply, reply_frame, new_conn} ->
        {:push, {:binary, Frame.encode!(reply_frame)}, %{state | connection: new_conn}}

      {:push, push_frame, new_conn} ->
        {:push, {:binary, Frame.encode!(push_frame)}, %{state | connection: new_conn}}

      {:noreply, new_conn} ->
        {:ok, %{state | connection: new_conn}}
    end
  end

  defp reason_to_binary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_binary(reason) when is_binary(reason), do: reason
  defp reason_to_binary(reason), do: inspect(reason)
end
