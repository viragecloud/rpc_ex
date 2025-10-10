defmodule RpcEx.Transport do
  @moduledoc """
  Behaviour for WebSocket transport implementations.

  The default implementation will target Bandit on the server and Mint on the
  client, but alternative adapters (e.g., Cowboy) can conform to this behaviour.
  """

  alias RpcEx.Protocol.Frame

  @type connect_option ::
          {:url, String.t()}
          | {:headers, [{binary(), binary()}]}
          | {:compression, :enabled | :disabled}
          | {:handshake, map()}
          | {:telemetry_prefix, [atom()]}

  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @callback start_link(keyword()) :: {:ok, pid()} | {:error, term()}

  @callback send_frame(pid(), Frame.t()) :: :ok | {:error, term()}

  @callback close(pid(), keyword()) :: :ok

  @callback info(pid()) :: map()
end
