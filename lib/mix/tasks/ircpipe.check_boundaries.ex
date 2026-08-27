defmodule Mix.Tasks.Ircpipe.CheckBoundaries do
  use Mix.Task

  @shortdoc "Checks logical application ownership and dependency boundaries"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    manifest = Mix.Ircpipe.Boundaries.load!("config/boundaries.exs")
    graph = xref_graph()

    case Mix.Ircpipe.Boundaries.check(manifest, graph) do
      {:ok, summary} ->
        Mix.shell().info(
          "Boundaries valid: #{summary.files} files, #{summary.dependencies} project dependencies, " <>
            "#{summary.temporary_dependencies} temporary dependencies"
        )

      {:error, errors} ->
        details = Enum.map_join(errors, "\n", &"  * #{&1}")
        Mix.raise("Logical application boundary check failed:\n#{details}")
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
