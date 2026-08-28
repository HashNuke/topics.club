defmodule Mix.TopicsClub.BoundariesTest do
  use ExUnit.Case, async: false

  alias Mix.TopicsClub.Boundaries

  @project_root Path.expand("../../..", __DIR__)

  @files [
    "lib/core.ex",
    "lib/engine.ex",
    "lib/shared.ex",
    "lib/tooling.ex",
    "lib/web.ex",
    "priv/repo/migrations/1_create_example.exs",
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

  test "prefixes and merges child-application graphs without losing edges" do
    child_graph = %{
      "lib/core.ex" => %{"lib/shared.ex" => "runtime"},
      "lib/shared.ex" => %{}
    }

    assert Boundaries.merge_graphs([
             %{"lib/web.ex" => %{}},
             Boundaries.prefix_graph(child_graph, "apps/topics_club_core")
           ]) == %{
             "lib/web.ex" => %{},
             "apps/topics_club_core/lib/core.ex" => %{
               "apps/topics_club_core/lib/shared.ex" => "runtime"
             },
             "apps/topics_club_core/lib/shared.ex" => %{}
           }
  end

  test "accepts the allowed deployable dependency directions" do
    graph =
      graph(%{
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

    temporary_manifest = %{
      manifest()
      | temporary_dependencies: [dependency],
        temporary_dependency_budget: 1
    }

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

  test "rejects temporary dependencies above the transition budget" do
    dependency = %{
      from: "lib/web.ex",
      to: "lib/engine.ex",
      label: "runtime",
      owner: :web,
      reason: "migration",
      remove_in: "checkpoint"
    }

    invalid_manifest = %{
      manifest()
      | temporary_dependencies: [dependency],
        temporary_dependency_budget: 0
    }

    assert {:error, errors} = Boundaries.check(invalid_manifest, graph(), @files)
    assert Enum.any?(errors, &String.contains?(&1, "exceeds budget"))
  end

  test "allows transition baselines only to shrink relative to the base branch" do
    dependency = %{
      from: "lib/web.ex",
      to: "lib/engine.ex",
      label: "runtime",
      owner: :web,
      reason: "migration",
      remove_in: "checkpoint"
    }

    cycle = temporary_cycle([:core, :web])

    base = %{
      manifest()
      | temporary_dependencies: [dependency],
        temporary_dependency_budget: 1,
        temporary_component_cycles: [cycle]
    }

    assert :ok = Boundaries.check_transition_regression(base, manifest())

    assert {:error, errors} = Boundaries.check_transition_regression(manifest(), base)
    assert Enum.any?(errors, &String.contains?(&1, "new temporary dependency"))
    assert Enum.any?(errors, &String.contains?(&1, "new temporary component cycle"))
    assert Enum.any?(errors, &String.contains?(&1, "budget increased from 0 to 1"))
  end

  test "rejects cycles in the deployable component graph" do
    cyclic_manifest =
      put_in(manifest(), [:allowed_dependencies, :shared], [:shared, :core])

    assert {:error, errors} = Boundaries.check(cyclic_manifest, graph(), @files)
    assert Enum.any?(errors, &String.contains?(&1, "dependency cycle"))
  end

  test "checks actual deployable cycles against the explicit transition baseline" do
    dependency = %{
      from: "lib/core.ex",
      to: "lib/web.ex",
      label: "runtime",
      owner: :core,
      reason: "migration",
      remove_in: "checkpoint"
    }

    cyclic_graph =
      graph(%{
        "lib/core.ex" => %{"lib/web.ex" => "runtime"},
        "lib/web.ex" => %{"lib/core.ex" => "runtime"}
      })

    without_cycle_baseline = %{
      manifest()
      | temporary_dependencies: [dependency],
        temporary_dependency_budget: 1
    }

    assert {:error, errors} =
             Boundaries.check(without_cycle_baseline, cyclic_graph, @files)

    assert Enum.any?(errors, &String.contains?(&1, "unapproved deployable component"))

    with_cycle_baseline = %{
      without_cycle_baseline
      | temporary_component_cycles: [temporary_cycle([:core, :web])]
    }

    assert {:ok, %{temporary_dependencies: 1}} =
             Boundaries.check(with_cycle_baseline, cyclic_graph, @files)
  end

  test "the checked-in ownership manifest covers production and test support" do
    File.cd!(@project_root, fn ->
      project_manifest =
        "config/boundaries.exs"
        |> Boundaries.load!()
        |> Map.put(:temporary_dependencies, [])
        |> Map.put(:temporary_component_cycles, [])

      files = Boundaries.tracked_files()
      production_graph = graph(Map.new(files, &{&1, %{}}))

      assert {:ok, %{files: file_count}} =
               Boundaries.check(project_manifest, production_graph, files)

      assert file_count == length(files)
      assert Enum.any?(files, &String.contains?(&1, "/priv/repo/migrations/"))
    end)
  end

  test "the project boundary Mix task passes" do
    assert {_output, 0} =
             System.cmd("mix", ["topics_club.check_boundaries"],
               cd: @project_root,
               env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
               stderr_to_stdout: true
             )
  end

  test "isolated child compilation rejects a call to an unavailable sibling module" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "topics_club-boundary-child-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(fixture_path, "lib"))

    File.write!(
      Path.join(fixture_path, "mix.exs"),
      """
      defmodule BoundaryChildFixture.MixProject do
        use Mix.Project

        def project do
          [app: :boundary_child_fixture, version: "0.1.0", elixir: "~> 1.15"]
        end
      end
      """
    )

    File.write!(
      Path.join(fixture_path, "lib/crossing.ex"),
      """
      defmodule BoundaryChildFixture.Crossing do
        def call, do: TopicsClubWeb.Endpoint.url()
      end
      """
    )

    on_exit(fn -> File.rm_rf!(fixture_path) end)

    assert {:error, _status, output} =
             Mix.Tasks.TopicsClub.CheckBoundaries.check_child_compilation(
               fixture_path,
               Path.join(fixture_path, "isolated_build")
             )

    assert output =~ "TopicsClubWeb.Endpoint.url/0 is undefined"
    assert output =~ "Compilation failed due to warnings"
  end

  test "compiler manifests expose a forbidden call to an available path dependency" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "topics_club-boundary-path-dependency-#{System.unique_integer([:positive, :monotonic])}"
      )

    engine_path = Path.join(fixture_path, "engine")
    build_path = Path.join(fixture_path, "build")
    File.mkdir_p!(Path.join(fixture_path, "lib"))
    File.mkdir_p!(Path.join(engine_path, "lib"))

    File.write!(
      Path.join(engine_path, "mix.exs"),
      """
      defmodule BoundaryEngineFixture.MixProject do
        use Mix.Project

        def project do
          [app: :boundary_engine_fixture, version: "0.1.0", elixir: "~> 1.15"]
        end
      end
      """
    )

    File.write!(
      Path.join(engine_path, "lib/engine.ex"),
      """
      defmodule BoundaryEngineFixture.API do
        def call, do: :ok
      end
      """
    )

    File.write!(
      Path.join(fixture_path, "mix.exs"),
      """
      defmodule BoundaryWebFixture.MixProject do
        use Mix.Project

        def project do
          [
            app: :boundary_web_fixture,
            version: "0.1.0",
            elixir: "~> 1.15",
            deps: [{:boundary_engine_fixture, path: "engine"}]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join(fixture_path, "lib/web.ex"),
      """
      defmodule BoundaryWebFixture.Crossing do
        def call, do: BoundaryEngineFixture.API.call()
      end
      """
    )

    on_exit(fn -> File.rm_rf!(fixture_path) end)

    assert {_output, 0} =
             System.cmd("mix", ["compile", "--warnings-as-errors"],
               cd: fixture_path,
               env: [
                 {"MIX_BUILD_PATH", build_path},
                 {"MIX_ENV", "test"}
               ],
               stderr_to_stdout: true
             )

    manifest_graph =
      Boundaries.manifest_graph([
        {Path.join([build_path, "lib/boundary_web_fixture/.mix/compile.elixir"]), ""},
        {Path.join([build_path, "lib/boundary_engine_fixture/.mix/compile.elixir"]),
         "apps/topics_club_engine"}
      ])

    engine_source = "apps/topics_club_engine/lib/engine.ex"
    assert manifest_graph["lib/web.ex"][engine_source] == "runtime"

    fixture_manifest =
      update_in(manifest(), [:ownership], fn ownership ->
        Enum.map(ownership, fn
          %{component: :engine} = rule -> %{rule | paths: [engine_source]}
          rule -> rule
        end)
      end)

    fixture_files = [engine_source | List.delete(@files, "lib/engine.ex")]

    assert {:error, errors} =
             Boundaries.check(
               fixture_manifest,
               Boundaries.merge_graphs([graph(), manifest_graph]),
               fixture_files
             )

    assert Enum.any?(errors, fn error ->
             String.contains?(error, "forbidden runtime dependency web -> engine")
           end)
  end

  defp manifest do
    %{
      version: 1,
      ownership: [
        rule(:core, ["lib/core.ex", "priv/repo/migrations/1_create_example.exs"]),
        rule(:engine, ["lib/engine.ex"]),
        rule(:shared, ["lib/shared.ex"]),
        rule(:tooling, ["lib/tooling.ex"]),
        rule(:web, ["lib/web.ex", "test/support/web_case.ex"])
      ],
      allowed_dependencies: %{
        core: [:core, :shared],
        engine: [:engine, :core, :shared],
        shared: [:shared],
        tooling: [:core, :engine, :shared, :tooling, :web],
        web: [:web, :core, :shared]
      },
      temporary_component_cycles: [],
      temporary_dependency_budget: 0,
      temporary_dependencies: []
    }
  end

  defp temporary_cycle(components) do
    %{
      components: components,
      reason: "migration",
      remove_in: "checkpoint"
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
