defmodule RpcEx.Peer do
  @moduledoc """
  Handle for making RPC calls to a connected peer (client or server).

  This module provides a way for handlers to initiate RPC calls to the other
  side of the connection. It's injected into the handler context to enable
  bidirectional RPC.
  """

  alias RpcEx.Protocol.Frame

  @type t :: %__MODULE__{
          handler_pid: pid(),
          timeout: non_neg_integer()
        }

  defstruct handler_pid: nil, timeout: 5_000

  @doc """
  Creates a new peer handle.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      handler_pid: Keyword.fetch!(opts, :handler_pid),
      timeout: Keyword.get(opts, :timeout, 5_000)
    }
  end

  @doc """
  Makes a synchronous RPC call to the peer.
  """
  @spec call(t(), RpcEx.route(), keyword()) :: {:ok, term(), map()} | {:error, term()}
  def call(%__MODULE__{} = peer, route, opts \\ []) do
    args = Keyword.get(opts, :args, %{})
    timeout = Keyword.get(opts, :timeout, peer.timeout)
    meta = Keyword.get(opts, :meta)
    msg_id = generate_id()

    payload = %{
      msg_id: msg_id,
      route: route,
      args: args,
      timeout_ms: timeout,
      meta: meta
    }

    frame = Frame.new(:call, payload)

    # Send request to handler process and wait for response
    ref = make_ref()
    send(peer.handler_pid, {:peer_call, ref, frame, self()})

    receive do
      {:peer_reply, ^ref, {:ok, result, meta}} ->
        {:ok, result, meta}

      {:peer_reply, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Sends a fire-and-forget cast to the peer.
  """
  @spec cast(t(), RpcEx.route(), keyword()) :: :ok
  def cast(%__MODULE__{} = peer, route, opts \\ []) do
    args = Keyword.get(opts, :args, %{})
    meta = Keyword.get(opts, :meta)

    payload = %{
      route: route,
      args: args,
      meta: meta
    }

    frame = Frame.new(:cast, payload)
    send(peer.handler_pid, {:peer_cast, frame})
    :ok
  end

  defp generate_id do
    :erlang.unique_integer([:positive, :monotonic])
    |> Integer.to_string(16)
  end
end
