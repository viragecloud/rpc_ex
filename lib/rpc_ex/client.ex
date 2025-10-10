defmodule RpcEx.Client do
  @moduledoc """
  Mint-based RPC client that manages a WebSocket connection to a remote peer.

  This module is responsible for establishing the connection, dispatching calls
  and casts, tracking in-flight requests, applying timeouts, and exposing
  telemetry events. Implementation is forthcoming; the current module defines
  the public API shape and option contracts.
  """

  @type option ::
          {:name, GenServer.name()}
          | {:url, String.t()}
          | {:router, module()}
          | {:timeout, non_neg_integer()}
          | {:compression, :enabled | :disabled}
          | {:reconnect, keyword()}
          | {:discovery, boolean()}
          | {:handshake, keyword()}
          | {:telemetry_prefix, [atom()]}

  @type call_option ::
          {:timeout, non_neg_integer()}
          | {:meta, map()}
          | {:retries, non_neg_integer()}
          | {:on_timeout, (term() -> term())}

  @typedoc "Reference returned by async calls."
  @type ref :: reference()

  @doc """
  Starts the client under a supervisor.
  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts) do
    {:error, :not_implemented}
  end

  @doc """
  Returns a child specification suitable for supervision trees.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Issues a synchronous RPC call.
  """
  @spec call(GenServer.name(), RpcEx.route(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call(_client, _route, _opts \\ []) do
    {:error, :not_implemented}
  end

  @doc """
  Dispatches an asynchronous RPC call, returning a reference that can be awaited.
  """
  @spec call_async(GenServer.name(), RpcEx.route(), keyword()) :: {:ok, ref()} | {:error, term()}
  def call_async(_client, _route, _opts \\ []) do
    {:error, :not_implemented}
  end

  @doc """
  Waits for the response of an async call started with `call_async/3`.
  """
  @spec await(ref(), timeout()) :: {:ok, term()} | {:error, term()}
  def await(_ref, _timeout \\ 5_000) do
    {:error, :not_implemented}
  end

  @doc """
  Emits a cast (fire-and-forget) operation to the remote peer.
  """
  @spec cast(GenServer.name(), RpcEx.route(), keyword()) :: :ok | {:error, term()}
  def cast(_client, _route, _opts \\ []) do
    {:error, :not_implemented}
  end

  @doc """
  Requests the remote peer to advertise available routes.
  """
  @spec discover(GenServer.name(), keyword()) :: {:ok, list()} | {:error, term()}
  def discover(_client, _opts \\ []) do
    {:error, :not_implemented}
  end
end
