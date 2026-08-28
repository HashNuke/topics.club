Path.join([__DIR__, "../lib/mix/**/*.ex"])
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

defmodule TopicsClub.IntegrationTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :topics_club_integration_test,
      version: "0.1.0",
      build_path: "../_build",
      config_path: "../config/config.exs",
      deps_path: "../deps",
      lockfile: "../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: [],
      test_paths: ["."],
      test_pattern: "*_test.exs",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:topics_club_core, path: "../apps/topics_club_core", env: Mix.env()},
      {:topics_club_engine, path: "../apps/topics_club_engine", env: Mix.env()},
      {:topics_club_gateway, path: "../apps/topics_club_gateway", env: Mix.env()}
    ]
  end
end
