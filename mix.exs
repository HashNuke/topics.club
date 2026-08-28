defmodule Ircpipe.MixProject do
  use Mix.Project

  def project do
    [
      app: :ircpipe,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Ircpipe.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ircpipe_core, path: "apps/ircpipe_core", env: Mix.env()},
      {:ircpipe_engine, path: "apps/ircpipe_engine", env: Mix.env()},
      {:ircpipe_web, path: "apps/ircpipe_web", env: Mix.env()}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "ircpipe.setup_local_irc", "assets.setup", "assets.build"],
      "ecto.setup": [
        "ecto.create -r Ircpipe.Repo",
        "ecto.migrate -r Ircpipe.Repo",
        "run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop -r Ircpipe.Repo", "ecto.setup"],
      test: [
        "ecto.create --quiet -r Ircpipe.Repo",
        "ecto.migrate --quiet -r Ircpipe.Repo",
        "cmd --cd apps/ircpipe_core mix test",
        "cmd --cd apps/ircpipe_engine mix test",
        "cmd --cd apps/ircpipe_web mix test",
        "test"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ircpipe", "esbuild ircpipe"],
      "assets.deploy": [
        "tailwind ircpipe --minify",
        "esbuild ircpipe --minify",
        "phx.digest apps/ircpipe_web/priv/static"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "ircpipe.check_boundaries",
        "deps.unlock --unused",
        "format",
        "cmd --cd apps/ircpipe_web/assets npm run typecheck",
        "cmd --cd apps/ircpipe_web/assets npm test",
        "cmd --cd apps/ircpipe_web/assets npm run build-storybook",
        "test"
      ]
    ]
  end
end
