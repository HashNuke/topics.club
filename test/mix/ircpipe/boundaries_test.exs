defmodule Mix.Ircpipe.BoundariesTest do
  use ExUnit.Case, async: false

  alias Mix.Ircpipe.Boundaries

  @files [
    "lib/assembly.ex",
    "lib/core.ex",
    "lib/engine.ex",
    "lib/shared.ex",
    "lib/tooling.ex",
    "lib/web.ex",
    "test/support/web_case.ex"
  ]

  test "parses runtime, export, and compile edges from xref DOT" do
    dot = """
    digraph "xref graph" {
      "lib/a.ex"
      "lib/a.ex" -> "lib/b.ex"
      "lib/b.ex" -> "lib/c.ex" [label="(export)"]
      "lib/c.ex" -> "lib/d.ex" [label="(compile)"]
      "lib/d.ex"
    }
    """

    assert Boundaries.parse_dot(dot) == %{
             "lib/a.ex" => %{"lib/b.ex" => "runtime"},
             "lib/b.ex" => %{"lib/c.ex" => "export"},
             "lib/c.ex" => %{"lib/d.ex" => "compile"},
             "lib/d.ex" => %{}
           }
  end

  test "fails closed for empty or unrecognized DOT" do
    assert_raise ArgumentError, ~r/invalid or empty/, fn -> Boundaries.parse_dot("") end

    assert_raise ArgumentError, ~r/contains no files/, fn ->
      Boundaries.parse_dot("digraph \"xref graph\" {\n}")
    end

    assert_raise ArgumentError, ~r/unrecognized xref DOT line/, fn ->
      Boundaries.parse_dot("digraph \"xref graph\" {\n  changed syntax\n}")
    end
  end

  test "accepts the allowed deployable dependency directions" do
    graph =
      graph(%{
        "lib/assembly.ex" => %{"lib/engine.ex" => "runtime"},
        "lib/core.ex" => %{"lib/shared.ex" => "export"},
        "lib/engine.ex" => %{"lib/core.ex" => "runtime"},
        "lib/tooling.ex" => %{"lib/web.ex" => "compile"},
        "lib/web.ex" => %{"lib/core.ex" => "runtime", "lib/shared.ex" => "runtime"}
      })

    assert {:ok, %{temporary_dependencies: 0}} =
             Boundaries.check(manifest(), graph, @files)
  end

  test "rejects unowned and multiply owned files" do
    assert {:error, errors} =
             Boundaries.check(manifest(), graph(), ["lib/orphan.ex" | @files])

    assert "unowned file: lib/orphan.ex" in errors

    overlapping_manifest =
      update_in(manifest(), [:ownership], fn ownership ->
        Enum.map(ownership, fn
          %{component: :core} = rule -> %{rule | paths: ["lib/shared.ex" | rule.paths]}
          rule -> rule
        end)
      end)

    assert {:error, overlap_errors} =
             Boundaries.check(overlapping_manifest, graph(), @files)

    assert Enum.any?(overlap_errors, &String.contains?(&1, "multiple owners"))
  end

  test "rejects forbidden dependencies" do
    invalid_graph = graph(%{"lib/web.ex" => %{"lib/engine.ex" => "runtime"}})

    assert {:error, errors} = Boundaries.check(manifest(), invalid_graph, @files)

    assert Enum.any?(errors, fn error ->
             String.contains?(error, "forbidden runtime dependency web -> engine")
           end)
  end

  test "accepts exact temporary dependencies and rejects stale labels" do
    dependency = %{
      from: "lib/web.ex",
      to: "lib/engine.ex",
      label: "runtime",
      owner: :web,
      reason: "migration",
      remove_in: "checkpoint"
    }

    temporary_manifest = %{manifest() | temporary_dependencies: [dependency]}
    runtime_graph = graph(%{"lib/web.ex" => %{"lib/engine.ex" => "runtime"}})

    assert {:ok, %{temporary_dependencies: 1}} =
             Boundaries.check(temporary_manifest, runtime_graph, @files)

    export_graph = graph(%{"lib/web.ex" => %{"lib/engine.ex" => "export"}})
    assert {:error, errors} = Boundaries.check(temporary_manifest, export_graph, @files)
    assert Enum.any?(errors, &String.contains?(&1, "forbidden export dependency"))
    assert Enum.any?(errors, &String.contains?(&1, "stale temporary dependency"))
  end

  test "rejects malformed, wildcard, and duplicate temporary dependencies" do
    dependency = %{
      from: "lib/*.ex",
      to: "lib/engine.ex",
      label: "runtime",
      owner: :web,
      reason: "migration",
      remove_in: "checkpoint"
    }

    invalid_manifest = %{manifest() | temporary_dependencies: [dependency, dependency]}

    assert {:error, errors} = Boundaries.check(invalid_manifest, graph(), @files)
    assert Enum.any?(errors, &String.contains?(&1, "must use exact file paths"))
    assert Enum.any?(errors, &String.contains?(&1, "duplicate temporary dependency"))

    malformed_manifest = %{
      manifest()
      | temporary_dependencies: [%{from: "lib/web.ex", to: "lib/engine.ex"}]
    }

    assert {:error, malformed_errors} =
             Boundaries.check(malformed_manifest, graph(), @files)

    assert Enum.any?(malformed_errors, &String.contains?(&1, "is missing keys"))
  end

  test "rejects cycles in the deployable component graph" do
    cyclic_manifest =
      put_in(manifest(), [:allowed_dependencies, :shared], [:shared, :core])

    assert {:error, errors} = Boundaries.check(cyclic_manifest, graph(), @files)
    assert Enum.any?(errors, &String.contains?(&1, "dependency cycle"))
  end

  test "the checked-in ownership manifest covers production and test support" do
    project_manifest =
      "config/boundaries.exs"
      |> Boundaries.load!()
      |> Map.put(:temporary_dependencies, [])

    files = Boundaries.tracked_files()
    production_graph = graph(Map.new(files, &{&1, %{}}))

    assert {:ok, %{files: file_count}} =
             Boundaries.check(project_manifest, production_graph, files)

    assert file_count == length(files)
  end

  test "the project boundary Mix task passes" do
    Mix.Task.reenable("ircpipe.check_boundaries")
    assert :ok = Mix.Tasks.Ircpipe.CheckBoundaries.run([])
  end

  defp manifest do
    %{
      version: 1,
      ownership: [
        rule(:assembly, ["lib/assembly.ex"]),
        rule(:core, ["lib/core.ex"]),
        rule(:engine, ["lib/engine.ex"]),
        rule(:shared, ["lib/shared.ex"]),
        rule(:tooling, ["lib/tooling.ex"]),
        rule(:web, ["lib/web.ex", "test/support/web_case.ex"])
      ],
      allowed_dependencies: %{
        assembly: [:assembly, :core, :engine, :shared, :web],
        core: [:core, :shared],
        engine: [:engine, :core, :shared],
        shared: [:shared],
        tooling: [:assembly, :core, :engine, :shared, :tooling, :web],
        web: [:web, :core, :shared]
      },
      temporary_dependencies: []
    }
  end

  defp rule(component, paths) do
    %{component: component, description: "#{component} test owner", paths: paths}
  end

  defp graph(overrides \\ %{}) do
    @files
    |> Enum.filter(&String.starts_with?(&1, "lib/"))
    |> Map.new(&{&1, %{}})
    |> Map.merge(overrides)
  end
end
