defmodule MyApp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/myorg/my_app"

  def project do
    [
      app: :my_app,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ],

      # Docs
      name: "MyApp",
      source_url: @source_url,
      docs: docs(),

      # Releases
      releases: releases()
    ]
  end

  def application do
    [
      mod: {MyApp.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  # --- Dependencies ---

  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},

      # Serialization
      {:jason, "~> 1.4"},

      # HTTP Client
      {:req, "~> 0.5"},

      # Telemetry & Monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Distributed Elixir
      {:libcluster, "~> 3.3"},

      # Background Jobs (pick one)
      {:oban, "~> 2.17"},

      # Dev & Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  # --- Compilation Paths ---

  # Include test/support in test compilation
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # --- Aliases ---

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      ci: ["lint", "test --cover"]
    ]
  end

  # --- Documentation ---

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Core: [MyApp],
        Workers: [~r/MyApp.Workers/],
        Schemas: [~r/MyApp.Schemas/]
      ]
    ]
  end

  # --- Releases ---

  defp releases do
    [
      my_app: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
