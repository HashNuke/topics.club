Path.join([__DIR__, "../lib/mix/**/*.ex"])
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

defmodule Ircpipe.IntegrationTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :ircpipe_integration_test,
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
      {:ircpipe_core, path: "../apps/ircpipe_core", env: Mix.env()},
      {:ircpipe_engine, path: "../apps/ircpipe_engine", env: Mix.env()},
      {:ircpipe_web, path: "../apps/ircpipe_web", env: Mix.env()}
    ]
  end
end
