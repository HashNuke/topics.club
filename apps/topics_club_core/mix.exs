defmodule TopicsClubCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :topics_club_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {TopicsClub.Core.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:cloak_ecto, "~> 1.3"},
      {:ecto_sql, "~> 3.13"},
      {:oban, "~> 2.24", runtime: false},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:ircxd, git: "https://github.com/HashNuke/ircxd.git", branch: "wirekeeper-transport"}
    ]
  end
end
