defmodule RpcEx.Router.Route do
  @moduledoc """
  Internal struct representing a compiled RPC route.

  Instances of this struct are generated at compile time by `RpcEx.Router` and
  embedded into the host module to support reflection and action discovery.
  """

  @enforce_keys [:name, :kind, :handler, :options]
  defstruct [:name, :kind, :handler, :options, metadata: %{}]

  @typedoc "The operation type supported by a route."
  @type kind :: :call | :cast

  @typedoc "Options captured from the DSL definition."
  @type options :: keyword()

  @typedoc "Function reference to the generated handler implementation."
  @type handler :: {module(), atom(), non_neg_integer()}

  @typedoc "Route metadata used for discovery."
  @type t :: %__MODULE__{
          name: RpcEx.route(),
          kind: kind(),
          handler: handler(),
          options: options(),
          metadata: map()
        }
end
