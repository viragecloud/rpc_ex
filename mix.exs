defmodule RpcEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :rpc_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      preferred_cli_env: [
        credo: :test,
        dialyzer: :dev,
        "hex.publish": :prod
      ],
      test_coverage: [
        ignore_modules: [~r/^RpcEx.Test/]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {RpcEx.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/integration/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:nimble_options, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:stream_data, "~> 0.6", only: :test},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp docs do
    [
      name: "RpcEx",
      source_url: "https://github.com/viragecloud/rpc_ex",
      homepage_url: "https://github.com/viragecloud/rpc_ex",
      main: "readme",
      extras: [
        "README.md",
        "docs/protocol.md",
        "docs/project_plan.md",
        "CLAUDE.md"
      ],
      groups_for_extras: [
        Introduction: ["README.md"],
        Guides: ["docs/protocol.md"],
        Development: ["docs/project_plan.md", "CLAUDE.md"]
      ],
      groups_for_modules: [
        "Client & Server": [
          RpcEx.Client,
          RpcEx.Server
        ],
        Protocol: [
          RpcEx.Protocol.Frame,
          RpcEx.Protocol.Handshake,
          RpcEx.Codec
        ],
        "Router & Routing": [
          RpcEx.Router,
          RpcEx.Router.Route,
          RpcEx.Router.Middleware,
          RpcEx.Reflection
        ],
        Runtime: [
          RpcEx.Runtime.Dispatcher,
          RpcEx.Peer
        ],
        "Internal - Client": [
          RpcEx.Client.Connection
        ],
        "Internal - Server": [
          RpcEx.Server.Endpoint,
          RpcEx.Server.Connection,
          RpcEx.Server.WebSocketHandler
        ],
        Authentication: [
          RpcEx.Server.Auth
        ]
      ]
    ]
  end
end
