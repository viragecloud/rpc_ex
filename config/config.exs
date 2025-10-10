import Config

config :rpc_ex,
  default_timeout_ms: 5_000,
  compression: :enabled

import_config "#{config_env()}.exs"
