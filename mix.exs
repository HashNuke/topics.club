Path.join([__DIR__, "lib/mix/**/*.ex"])
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

defmodule Ircpipe.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: [],
      releases: releases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp releases do
    [
      ircpipe: [
        applications: [
          ircpipe_core: :permanent,
          ircpipe_engine: :permanent,
          ircpipe_web: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "ircpipe.setup_local_irc", "assets.setup", "assets.build"],
      "ecto.setup": [&ecto_setup/1],
      "ecto.reset": [&ecto_reset/1],
      test: [&test/1],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ircpipe", "esbuild ircpipe"],
      "assets.deploy": [
        "tailwind ircpipe --minify",
        "esbuild ircpipe --minify",
        &digest_assets/1
      ],
      precommit: [
        "compile --warnings-as-errors",
        "ircpipe.check_boundaries",
        "deps.unlock --unused",
        "format",
        &frontend_typecheck/1,
        &frontend_test/1,
        &storybook_build/1,
        "test"
      ]
    ]
  end

  defp ecto_setup(_args) do
    run_mix!("apps/ircpipe_core", ["ecto.create", "-r", "Ircpipe.Repo"])
    run_mix!("apps/ircpipe_core", ["ecto.migrate", "-r", "Ircpipe.Repo"])
    run_mix!("apps/ircpipe_web", ["run", "../../priv/repo/seeds.exs"])
  end

  defp ecto_reset(_args) do
    run_mix!("apps/ircpipe_core", ["ecto.drop", "-r", "Ircpipe.Repo"])
    ecto_setup([])
  end

  defp test(args) do
    run_mix!("apps/ircpipe_core", ["ecto.create", "--quiet", "-r", "Ircpipe.Repo"])
    run_mix!("apps/ircpipe_core", ["ecto.migrate", "--quiet", "-r", "Ircpipe.Repo"])

    case test_target(args) do
      {:child, child_path, child_args} ->
        run_mix!(child_path, ["test" | child_args])

      {:integration, integration_args} ->
        run_mix!("test", ["test" | integration_args])

      :all ->
        Enum.each(["apps/ircpipe_core", "apps/ircpipe_engine", "apps/ircpipe_web"], fn path ->
          run_mix!(path, ["test" | args])
        end)

        run_mix!("test", ["test" | args])
    end
  end

  defp test_target(args) do
    targets = [
      {"apps/ircpipe_core/", "apps/ircpipe_core"},
      {"apps/ircpipe_engine/", "apps/ircpipe_engine"},
      {"apps/ircpipe_web/", "apps/ircpipe_web"}
    ]

    Enum.find_value(Enum.with_index(args), :all, fn {arg, index} ->
      case Enum.find(targets, &String.starts_with?(arg, elem(&1, 0))) do
        {prefix, child_path} ->
          {:child, child_path, List.replace_at(args, index, String.trim_leading(arg, prefix))}

        nil ->
          if arg == "test" or String.starts_with?(arg, "test/") do
            relative = if arg == "test", do: ".", else: String.trim_leading(arg, "test/")
            {:integration, List.replace_at(args, index, relative)}
          end
      end
    end)
  end

  defp frontend_typecheck(_args), do: run_npm!(["run", "typecheck"])
  defp frontend_test(_args), do: run_npm!(["test"])
  defp storybook_build(_args), do: run_npm!(["run", "build-storybook"])
  defp digest_assets(_args), do: run_mix!("apps/ircpipe_web", ["phx.digest", "priv/static"])

  defp run_npm!(args), do: run_command!("npm", args, "apps/ircpipe_web/assets")
  defp run_mix!(path, args), do: run_command!("mix", args, path)

  defp run_command!(command, args, path) do
    {_stream, status} =
      System.cmd(command, args,
        cd: Path.join(__DIR__, path),
        env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
        into: IO.stream(:stdio, :line)
      )

    if status != 0 do
      Mix.raise("#{command} #{Enum.join(args, " ")} failed in #{path} with exit #{status}")
    end
  end
end
