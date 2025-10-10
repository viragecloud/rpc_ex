defmodule RpcEx.Reflection do
  @moduledoc """
  Utilities for inspecting routers and generating discovery metadata.
  """

  alias RpcEx.Router.Route

  @type entry :: %{
          route: RpcEx.route(),
          kind: Route.kind(),
          options: Route.options(),
          metadata: map()
        }

  @doc """
  Extracts discovery entries from a router module.
  """
  @spec describe(module()) :: [entry()]
  def describe(router) when is_atom(router) do
    router.__rpc_routes__()
    |> Enum.map(&route_to_entry/1)
  rescue
    _ -> []
  end

  defp route_to_entry(%Route{} = route) do
    %{
      route: route.name,
      kind: route.kind,
      options: route.options,
      metadata: route.metadata
    }
  end
end
