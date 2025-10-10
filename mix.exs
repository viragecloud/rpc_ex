defmodule RpcEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :rpc_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      preferred_cli_env: [
        credo: :test,
        dialyzer: :dev,
        "hex.publish": :prod
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
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/project_plan.md",
        "docs/protocol.md",
        "docs/api_usage_examples.md"
      ]
    ]
  end
end
