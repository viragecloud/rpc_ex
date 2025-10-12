defmodule RpcEx.Horde do
  @moduledoc """
  Convenience helpers for wiring RpcEx with Horde-based clustering.

  This module exposes child specs for Horde registries and supervisors as well as
  a helper for joining nodes into the same Horde cluster.
  """

  alias Horde.{Cluster, DynamicSupervisor, Registry}

  @doc """
  Returns a child specification for a Horde registry.
  """
  @spec registry_child_spec(keyword()) :: Supervisor.child_spec()
  def registry_child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    keys = Keyword.get(opts, :keys, :duplicate)
    members = Keyword.get(opts, :members)

    registry_opts =
      opts
      |> Keyword.take([:listeners, :meta])
      |> Keyword.merge(name: name, keys: keys, members: members || :auto)

    %{
      id: Keyword.get(opts, :id, name),
      start: {Registry, :start_link, [registry_opts]},
      type: :worker,
      shutdown: 10_000
    }
  end

  @doc """
  Returns a child specification for a Horde dynamic supervisor.
  """
  @spec client_supervisor_spec(keyword()) :: Supervisor.child_spec()
  def client_supervisor_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    sup_opts =
      opts
      |> Keyword.take([:strategy, :distribution_strategy, :max_children])
      |> Keyword.merge(name: name, strategy: :one_for_one)

    %{
      id: Keyword.get(opts, :id, name),
      start: {DynamicSupervisor, :start_link, [sup_opts]},
      type: :supervisor,
      shutdown: 15_000
    }
  end

  @doc """
  Declares the set of members for a Horde component.
  """
  @spec join(atom(), [atom()]) :: :ok
  def join(name, members) when is_atom(name) do
    members =
      [name | List.wrap(members)]
      |> Enum.map(&qualify_member/1)
      |> MapSet.new()

    Cluster.set_members(name, members)
  end

  defp qualify_member({member, node}) when is_atom(member) and is_atom(node), do: {member, node}
  defp qualify_member(member) when is_atom(member), do: {member, node()}
end
