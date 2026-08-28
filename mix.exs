Path.join([__DIR__, "lib/mix/**/*.ex"])
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

defmodule TopicsClub.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      default_release: :topics_club,
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
    version = release_version()

    [
      topics_club:
        release(version, [:topics_club_core, :topics_club_engine, :topics_club_gateway], [
          "rel/web"
        ]),
      topics_club_gateway:
        release(version, [:topics_club_core, :topics_club_gateway], ["rel/web"]),
      topics_club_engine: release(version, [:topics_club_core, :topics_club_engine])
    ]
  end

  defp release(version, applications, overlays \\ []) do
    [
      version: version,
      include_executables_for: [:unix],
      applications: Enum.map(applications, &{&1, :permanent}),
      overlays: overlays
    ]
  end

  defp release_version do
    revision =
      System.get_env("TOPICS_CLUB_SOURCE_REVISION") ||
        System.get_env("RAILWAY_GIT_COMMIT_SHA") ||
        git_revision() ||
        "unknown"

    revision =
      revision
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^0-9a-z-]/, "")
      |> String.slice(0, 12)

    "#{@version}+#{if revision == "", do: "unknown", else: revision}"
  end

  defp git_revision do
    with git when is_binary(git) <- System.find_executable("git"),
         {revision, 0} <-
           System.cmd(git, ["rev-parse", "--verify", "HEAD"], stderr_to_stdout: true) do
      revision
    else
      _unavailable -> nil
    end
  end

  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "topics_club.setup_local_irc",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": [&ecto_setup/1],
      "ecto.reset": [&ecto_reset/1],
      test: [&test/1],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind topics_club", "esbuild topics_club"],
      "assets.deploy": [
        "compile",
        "tailwind topics_club --minify",
        "esbuild topics_club --minify",
        &digest_assets/1
      ],
      precommit: [
        "compile --warnings-as-errors",
        "topics_club.check_boundaries",
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
    run_mix!("apps/topics_club_core", ["ecto.create", "-r", "Ircpipe.Repo"])
    run_mix!("apps/topics_club_core", ["ecto.migrate", "-r", "Ircpipe.Repo"])
    run_mix!("apps/topics_club_gateway", ["run", "../../priv/repo/seeds.exs"])
  end

  defp ecto_reset(_args) do
    run_mix!("apps/topics_club_core", ["ecto.drop", "-r", "Ircpipe.Repo"])
    ecto_setup([])
  end

  defp test(args) do
    run_mix!("apps/topics_club_core", ["ecto.create", "--quiet", "-r", "Ircpipe.Repo"])
    run_mix!("apps/topics_club_core", ["ecto.migrate", "--quiet", "-r", "Ircpipe.Repo"])

    case test_target(args) do
      {:child, child_path, child_args} ->
        run_mix!(child_path, ["test" | child_args])

      {:integration, integration_args} ->
        run_mix!("test", ["test" | integration_args])

      :all ->
        Enum.each(
          ["apps/topics_club_core", "apps/topics_club_engine", "apps/topics_club_gateway"],
          fn path ->
            run_mix!(path, ["test" | args])
          end
        )

        run_mix!("test", ["test" | args])
    end
  end

  defp test_target(args) do
    targets = [
      {"apps/topics_club_core/", "apps/topics_club_core"},
      {"apps/topics_club_engine/", "apps/topics_club_engine"},
      {"apps/topics_club_gateway/", "apps/topics_club_gateway"}
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

  defp digest_assets(_args),
    do: run_mix!("apps/topics_club_gateway", ["phx.digest", "priv/static"])

  defp run_npm!(args), do: run_command!("npm", args, "apps/topics_club_gateway/assets")
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
