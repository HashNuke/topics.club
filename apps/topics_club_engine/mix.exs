defmodule TopicsClubEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :topics_club_engine,
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
      mod: {Ircpipe.Engine.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:topics_club_core, in_umbrella: true},
      {:ecto_sql, "~> 3.13"},
      {:oban, "~> 2.24"},
      {:ircxd, github: "HashNuke/ircxd", branch: "main"}
    ]
  end
end
