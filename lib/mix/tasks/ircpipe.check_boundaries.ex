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
    graph = xref_graph()

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

  defp xref_graph do
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
end
