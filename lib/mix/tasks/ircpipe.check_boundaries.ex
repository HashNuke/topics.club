defmodule Mix.Tasks.Ircpipe.CheckBoundaries do
  use Mix.Task

  @shortdoc "Checks logical application ownership and dependency boundaries"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [baseline_ref: :string])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix ircpipe.check_boundaries [--baseline-ref GIT_REF]")
    end

    Mix.Task.run("compile")

    manifest = Mix.Ircpipe.Boundaries.load!("config/boundaries.exs")
    child_paths = child_project_paths()
    Enum.each(child_paths, &compile_child!/1)
    graph = xref_graph(child_paths)

    with {:ok, summary} <- Mix.Ircpipe.Boundaries.check(manifest, graph),
         :ok <- check_baseline(opts[:baseline_ref], manifest) do
      Mix.shell().info(
        "Boundaries valid: #{summary.files} files, #{summary.dependencies} project dependencies, " <>
          "#{summary.temporary_dependencies} temporary dependencies"
      )
    else
      {:error, errors} when is_list(errors) ->
        details = Enum.map_join(errors, "\n", &"  * #{&1}")
        Mix.raise("Logical application boundary check failed:\n#{details}")

      {:error, reason} ->
        Mix.raise("Logical application boundary check failed: #{reason}")
    end
  end

  defp check_baseline(nil, _manifest), do: :ok

  defp check_baseline(ref, manifest) do
    case System.cmd("git", ["show", "#{ref}:config/boundaries.exs"], stderr_to_stdout: true) do
      {source, 0} ->
        ref
        |> then(&Mix.Ircpipe.Boundaries.load_source!(source, "#{&1}:config/boundaries.exs"))
        |> Mix.Ircpipe.Boundaries.check_transition_regression(manifest)

      {output, _status} ->
        {:error, "could not load boundary baseline #{inspect(ref)}: #{String.trim(output)}"}
    end
  end

  @doc false
  def check_child_compilation(child_path, build_path) do
    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: child_path,
           env: [
             {"MIX_BUILD_PATH", Path.expand(build_path)},
             {"MIX_ENV", Atom.to_string(Mix.env())}
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, status, output}
    end
  end

  defp child_project_paths do
    "apps/*/mix.exs"
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
  end

  defp compile_child!(child_path) do
    build_path =
      Path.join([
        File.cwd!(),
        "_build",
        "boundary",
        Atom.to_string(Mix.env()),
        Path.basename(child_path)
      ])

    case check_child_compilation(child_path, build_path) do
      :ok ->
        :ok

      {:error, status, output} ->
        Mix.raise(
          "isolated warnings-as-errors compile failed for #{child_path} " <>
            "(exit #{status}):\n#{output}"
        )
    end
  end

  defp xref_graph(child_paths) do
    root_graphs =
      if Mix.Project.umbrella?() do
        []
      else
        [xref_graph_for_current_project()]
      end

    child_graphs =
      Enum.map(child_paths, fn child_path ->
        child_path
        |> xref_graph_for_child()
        |> Mix.Ircpipe.Boundaries.prefix_graph(child_path)
      end)

    manifest_graph =
      child_paths
      |> project_manifests()
      |> Mix.Ircpipe.Boundaries.manifest_graph()

    Mix.Ircpipe.Boundaries.merge_graphs(root_graphs ++ [manifest_graph | child_graphs])
  end

  defp project_manifests(child_paths) do
    build_path = Mix.Project.build_path()

    child_manifests =
      Enum.map(child_paths, fn child_path ->
        manifest =
          Path.join([
            build_path,
            "lib",
            Path.basename(child_path),
            ".mix",
            "compile.elixir"
          ])

        {manifest, child_path}
      end)

    if Mix.Project.umbrella?() do
      child_manifests
    else
      root_manifest = Path.join(Mix.Project.manifest_path(), "compile.elixir")
      [{root_manifest, ""} | child_manifests]
    end
  end

  defp xref_graph_for_current_project do
    output_path =
      Path.join(
        System.tmp_dir!(),
        "ircpipe-xref-#{System.unique_integer([:positive, :monotonic])}.dot"
      )

    try do
      Mix.Task.reenable("xref")

      Mix.Tasks.Xref.run([
        "graph",
        "--format",
        "dot",
        "--only-direct",
        "--output",
        output_path,
        "--no-compile"
      ])

      output_path
      |> File.read!()
      |> Mix.Ircpipe.Boundaries.parse_dot()
    after
      File.rm(output_path)
    end
  end

  defp xref_graph_for_child(child_path) do
    output_path =
      Path.join(
        System.tmp_dir!(),
        "ircpipe-xref-child-#{System.unique_integer([:positive, :monotonic])}.dot"
      )

    args = [
      "xref",
      "graph",
      "--format",
      "dot",
      "--only-direct",
      "--output",
      output_path,
      "--no-compile"
    ]

    try do
      case System.cmd("mix", args,
             cd: child_path,
             env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          output_path
          |> File.read!()
          |> Mix.Ircpipe.Boundaries.parse_dot()

        {output, status} ->
          Mix.raise("could not build xref graph for #{child_path} (exit #{status}):\n#{output}")
      end
    after
      File.rm(output_path)
    end
  end
end
