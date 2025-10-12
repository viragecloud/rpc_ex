defmodule RpcEx.Horde.ServerRegistry do
  @moduledoc """
  Utilities for working with Horde-registered server-side connections.

  The registry exposes helper functions to list available connections and to
  build `RpcEx.Peer` handles that can be used to communicate with clients from
  anywhere in the cluster.
  """

  alias Horde.Registry
  alias RpcEx.Peer

  @doc """
  Returns the registered WebSocket connection processes and their metadata.
  """
  @spec connections(atom(), term()) :: list({pid(), map()})
  def connections(registry, key \\ :connections) when is_atom(registry) do
    registry
    |> Registry.match(key, :_, [])
    |> Enum.filter(fn {pid, _meta} -> Process.alive?(pid) end)
  rescue
    _ -> []
  end

  @doc """
  Builds ready-to-use peer handles for all healthy connections in the registry.
  """
  @spec peers(atom(), term(), keyword()) :: list({Peer.t(), map()})
  def peers(registry, key \\ :connections, opts \\ []) do
    default_timeout = Keyword.get(opts, :timeout, 5_000)

    connections(registry, key)
    |> Enum.filter(fn {_pid, meta} -> Map.get(meta, :status) == :ready end)
    |> Enum.map(fn {pid, meta} ->
      timeout = Map.get(meta, :timeout, default_timeout)
      {Peer.new(handler_pid: pid, timeout: timeout), meta}
    end)
  end

  @doc """
  Picks a single healthy peer from the registry.
  """
  @spec pick_peer(atom(), term(), keyword()) :: {:ok, Peer.t(), map()} | {:error, term()}
  def pick_peer(registry, key \\ :connections, opts \\ []) do
    case peers(registry, key, opts) do
      [] ->
        {:error, :no_available_clients}

      list ->
        {peer, meta} = Enum.random(list)
        {:ok, peer, meta}
    end
  end
end
