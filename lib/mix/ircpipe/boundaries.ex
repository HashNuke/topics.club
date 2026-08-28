defmodule Mix.Ircpipe.Boundaries do
  @moduledoc false

  import Mix.Compilers.Elixir,
    only: [module: 1, read_manifest: 1, source: 1]

  @type graph :: %{String.t() => %{String.t() => String.t()}}

  @dot_edge ~r/^\s*"([^"]+)" -> "([^"]+)"(?: \[label="\((compile|export)\)"\])?$/
  @dot_node ~r/^\s*"([^"]+)"$/
  @components MapSet.new([:core, :engine, :shared, :tooling, :web])
  @deployable_components MapSet.new([:core, :engine, :shared, :web])

  def load!(path) do
    {manifest, _binding} = Code.eval_file(path)
    manifest
  end

  def load_source!(source, filename) when is_binary(source) and is_binary(filename) do
    {manifest, _binding} = Code.eval_string(source, [], file: filename)
    manifest
  end

  def check_transition_regression(base_manifest, current_manifest) do
    errors =
      regression_errors(
        "temporary dependency",
        Map.fetch!(base_manifest, :temporary_dependencies),
        Map.fetch!(current_manifest, :temporary_dependencies)
      ) ++
        regression_errors(
          "temporary component cycle",
          Map.fetch!(base_manifest, :temporary_component_cycles),
          Map.fetch!(current_manifest, :temporary_component_cycles)
        ) ++
        budget_regression_errors(base_manifest, current_manifest)

    if errors == [], do: :ok, else: {:error, Enum.sort(errors)}
  end

  def tracked_files(root \\ File.cwd!()) do
    [
      "lib/**/*.ex",
      "apps/*/lib/**/*.ex",
      "apps/*/priv/repo/migrations/*.exs",
      "test/support/**/*.ex",
      "apps/*/test/support/**/*.ex"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.map(&normalize_path/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def parse_dot(dot) when is_binary(dot) do
    lines = String.split(dot, "\n", trim: true)

    unless List.first(lines) == "digraph \"xref graph\" {" and List.last(lines) == "}" do
      raise ArgumentError, "invalid or empty xref DOT graph"
    end

    graph =
      lines
      |> Enum.slice(1, max(length(lines) - 2, 0))
      |> Enum.reduce(%{}, fn line, graph ->
        cond do
          match = Regex.run(@dot_edge, line) ->
            case match do
              [_line, source, sink] -> put_graph_edge(graph, source, sink, "runtime")
              [_line, source, sink, label] -> put_graph_edge(graph, source, sink, label)
            end

          match = Regex.run(@dot_node, line) ->
            [_line, node] = match
            Map.put_new(graph, node, %{})

          true ->
            raise ArgumentError, "unrecognized xref DOT line: #{line}"
        end
      end)

    if map_size(graph) == 0, do: raise(ArgumentError, "xref DOT graph contains no files")
    graph
  end

  def prefix_graph(graph, prefix) when is_map(graph) and is_binary(prefix) do
    Map.new(graph, fn {source, sinks} ->
      prefixed_sinks = Map.new(sinks, fn {sink, label} -> {Path.join(prefix, sink), label} end)
      {Path.join(prefix, source), prefixed_sinks}
    end)
  end

  def merge_graphs(graphs) when is_list(graphs) do
    Enum.reduce(graphs, %{}, fn graph, merged ->
      Map.merge(merged, graph, fn _source, left_sinks, right_sinks ->
        Map.merge(left_sinks, right_sinks)
      end)
    end)
  end

  @doc false
  def manifest_graph(manifests) when is_list(manifests) do
    projects = Enum.map(manifests, &read_project_manifest!/1)

    module_sources =
      for %{modules: modules, prefix: prefix} <- projects,
          {module_name, module(sources: sources)} <- modules,
          source_path <- sources,
          do: {module_name, prefixed_path(prefix, source_path)}

    duplicate_modules =
      module_sources
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.flat_map(fn
        {_module_name, 1} -> []
        {module_name, _count} -> [module_name]
      end)

    if duplicate_modules != [] do
      raise ArgumentError,
            "modules occur in more than one project compiler manifest: #{inspect(Enum.sort(duplicate_modules))}"
    end

    module_sources = Map.new(module_sources)

    Enum.reduce(projects, %{}, fn %{prefix: prefix, sources: sources}, graph ->
      Enum.reduce(sources, graph, fn {source_path, source_entry}, graph ->
        source_path = prefixed_path(prefix, source_path)

        source(
          compile_references: compile_references,
          export_references: export_references,
          runtime_references: runtime_references
        ) = source_entry

        graph
        |> Map.put_new(source_path, %{})
        |> put_module_reference_edges(
          source_path,
          runtime_references,
          "runtime",
          module_sources
        )
        |> put_module_reference_edges(
          source_path,
          export_references,
          "export",
          module_sources
        )
        |> put_module_reference_edges(
          source_path,
          compile_references,
          "compile",
          module_sources
        )
      end)
    end)
  end

  def check(manifest, graph, tracked_files \\ tracked_files()) do
    with :ok <- validate_manifest(manifest),
         {:ok, ownership} <- build_ownership(manifest, tracked_files),
         :ok <- validate_allowed_dependencies(manifest, ownership),
         :ok <- validate_temporary_component_cycles(manifest),
         :ok <- validate_temporary_dependencies(manifest, ownership),
         {:ok, dependency_summary} <- check_dependencies(manifest, graph, ownership) do
      {:ok,
       %{
         files: map_size(ownership),
         dependencies: dependency_summary.dependencies,
         temporary_dependencies: dependency_summary.temporary_dependencies,
         ownership: ownership
       }}
    end
  end

  defp validate_manifest(%{version: 1, ownership: ownership} = manifest)
       when is_list(ownership) do
    components = Enum.map(ownership, &Map.get(&1, :component))
    component_set = MapSet.new(components)

    rule_errors =
      ownership
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {rule, index} ->
        cond do
          not is_atom(Map.get(rule, :component)) ->
            ["ownership rule #{index} has no atom component"]

          not nonempty_string?(Map.get(rule, :description)) ->
            ["ownership rule #{index} has no description"]

          not is_list(Map.get(rule, :paths)) or Map.get(rule, :paths) == [] ->
            ["ownership rule #{index} has no paths"]

          true ->
            []
        end
      end)

    duplicate_components =
      components
      |> Enum.frequencies()
      |> Enum.flat_map(fn
        {_component, 1} -> []
        {component, _count} -> ["duplicate ownership component: #{inspect(component)}"]
      end)

    component_errors =
      if MapSet.equal?(component_set, @components) do
        []
      else
        missing = MapSet.difference(@components, component_set) |> Enum.sort()
        unknown = MapSet.difference(component_set, @components) |> Enum.sort()

        [
          "ownership components differ from the required set; missing=#{inspect(missing)} unknown=#{inspect(unknown)}"
        ]
      end

    if is_map(Map.get(manifest, :allowed_dependencies)) do
      case Enum.sort(rule_errors ++ duplicate_components ++ component_errors) do
        [] -> :ok
        errors -> {:error, errors}
      end
    else
      {:error, ["manifest has no allowed dependency map" | rule_errors ++ duplicate_components]}
    end
  end

  defp validate_manifest(_manifest),
    do: {:error, ["boundary manifest must use version 1 and contain ownership rules"]}

  defp build_ownership(manifest, tracked_files) do
    rules = Map.fetch!(manifest, :ownership)

    ownership =
      Map.new(tracked_files, fn file ->
        owners =
          for rule <- rules,
              file in expanded_paths(rule),
              do: Map.fetch!(rule, :component)

        {file, owners}
      end)

    errors =
      Enum.flat_map(ownership, fn
        {file, []} -> ["unowned file: #{file}"]
        {_file, [_owner]} -> []
        {file, owners} -> ["file has multiple owners #{inspect(owners)}: #{file}"]
      end)

    if errors == [] do
      {:ok, Map.new(ownership, fn {file, [owner]} -> {file, owner} end)}
    else
      {:error, Enum.sort(errors)}
    end
  end

  defp expanded_paths(rule) do
    included = expand_patterns(Map.fetch!(rule, :paths))
    excluded = expand_patterns(Map.get(rule, :exclude, []))
    MapSet.difference(included, excluded)
  end

  defp expand_patterns(patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      if String.contains?(pattern, ["*", "?", "["]) do
        Path.wildcard(pattern)
      else
        [pattern]
      end
    end)
    |> Enum.map(&normalize_path/1)
    |> MapSet.new()
  end

  defp validate_allowed_dependencies(manifest, ownership) do
    allowed_dependencies = Map.fetch!(manifest, :allowed_dependencies)
    owners = ownership |> Map.values() |> MapSet.new()
    configured_owners = allowed_dependencies |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(owners, configured_owners) |> Enum.sort()
    extra = MapSet.difference(configured_owners, owners) |> Enum.sort()

    unknown_targets =
      allowed_dependencies
      |> Enum.flat_map(fn {owner, targets} ->
        if is_list(targets) do
          targets
          |> Enum.reject(&MapSet.member?(owners, &1))
          |> Enum.map(&"#{inspect(owner)} allows unknown owner #{inspect(&1)}")
        else
          ["#{inspect(owner)} allowed dependencies must be a list"]
        end
      end)

    errors =
      if missing == [],
        do: unknown_targets,
        else: ["owners missing allowed dependency rules: #{inspect(missing)}" | unknown_targets]

    errors =
      if extra == [],
        do: errors,
        else: ["allowed dependency rules have unknown owners: #{inspect(extra)}" | errors]

    errors = errors ++ dependency_cycle_errors(allowed_dependencies)

    if errors == [], do: :ok, else: {:error, Enum.sort(errors)}
  end

  defp validate_temporary_dependencies(manifest, ownership) do
    temporary_dependencies = Map.fetch!(manifest, :temporary_dependencies)
    temporary_dependency_budget = Map.get(manifest, :temporary_dependency_budget)

    errors =
      temporary_dependencies
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {dependency, index} ->
        missing =
          [:from, :to, :label, :owner, :reason, :remove_in]
          |> Enum.reject(&Map.has_key?(dependency, &1))

        empty =
          [:reason, :remove_in]
          |> Enum.filter(fn key ->
            case Map.get(dependency, key) do
              value when is_binary(value) -> String.trim(value) == ""
              _value -> true
            end
          end)

        cond do
          missing != [] ->
            ["temporary dependency #{index} is missing keys: #{inspect(missing)}"]

          empty != [] ->
            ["temporary dependency #{index} has empty metadata: #{inspect(empty)}"]

          not is_atom(Map.get(dependency, :owner)) ->
            ["temporary dependency #{index} has no atom owner"]

          wildcard_path?(Map.fetch!(dependency, :from)) or
              wildcard_path?(Map.fetch!(dependency, :to)) ->
            ["temporary dependency #{index} must use exact file paths"]

          not Map.has_key?(ownership, Map.get(dependency, :from)) ->
            ["temporary dependency #{index} has an unowned source path"]

          not Map.has_key?(ownership, Map.get(dependency, :to)) ->
            ["temporary dependency #{index} has an unowned target path"]

          Map.fetch!(ownership, Map.fetch!(dependency, :from)) != Map.get(dependency, :owner) ->
            ["temporary dependency #{index} owner does not match its source component"]

          Map.get(dependency, :label) not in ["compile", "export", "runtime"] ->
            ["temporary dependency #{index} has an invalid dependency label"]

          true ->
            []
        end
      end)

    duplicate_edges =
      temporary_dependencies
      |> Enum.group_by(&{Map.get(&1, :from), Map.get(&1, :to)})
      |> Enum.flat_map(fn
        {_edge, [_dependency]} -> []
        {{source, sink}, _duplicates} -> ["duplicate temporary dependency: #{source} -> #{sink}"]
      end)

    budget_errors =
      cond do
        not is_integer(temporary_dependency_budget) or temporary_dependency_budget < 0 ->
          ["temporary dependency budget must be a non-negative integer"]

        length(temporary_dependencies) > temporary_dependency_budget ->
          [
            "temporary dependency count #{length(temporary_dependencies)} exceeds budget #{temporary_dependency_budget}"
          ]

        true ->
          []
      end

    case Enum.sort(errors ++ duplicate_edges ++ budget_errors) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check_dependencies(manifest, graph, ownership) do
    allowed_dependencies = Map.fetch!(manifest, :allowed_dependencies)
    temporary_dependencies = Map.fetch!(manifest, :temporary_dependencies)

    project_edges =
      for {source, sinks} <- graph,
          {sink, label} <- sinks,
          Map.has_key?(ownership, normalize_path(source)),
          Map.has_key?(ownership, normalize_path(sink)),
          do: {normalize_path(source), normalize_path(sink), label}

    production_files =
      for {file, component} <- ownership,
          MapSet.member?(@deployable_components, component),
          production_file?(file),
          do: file

    missing_graph_files = Enum.reject(production_files, &Map.has_key?(graph, &1))

    forbidden_edges =
      Enum.reject(project_edges, fn {source, sink, _label} ->
        source_owner = Map.fetch!(ownership, source)
        sink_owner = Map.fetch!(ownership, sink)
        sink_owner in Map.fetch!(allowed_dependencies, source_owner)
      end)

    {accepted_edges, violations} =
      Enum.split_with(forbidden_edges, fn {source, sink, label} ->
        temporary_dependency?(temporary_dependencies, source, sink, label)
      end)

    used_temporary_dependencies =
      MapSet.new(accepted_edges, fn {source, sink, label} -> {source, sink, label} end)

    stale_temporary_dependencies =
      Enum.reject(temporary_dependencies, fn dependency ->
        MapSet.member?(
          used_temporary_dependencies,
          {
            Map.fetch!(dependency, :from),
            Map.fetch!(dependency, :to),
            Map.fetch!(dependency, :label)
          }
        )
      end)

    errors =
      Enum.map(violations, fn {source, sink, label} ->
        source_owner = Map.fetch!(ownership, source)
        sink_owner = Map.fetch!(ownership, sink)

        "forbidden #{label} dependency #{source_owner} -> #{sink_owner}: #{source} -> #{sink}"
      end) ++
        Enum.map(missing_graph_files, &"production file missing from xref graph: #{&1}") ++
        Enum.map(stale_temporary_dependencies, fn dependency ->
          "stale temporary dependency: #{dependency.from} -> #{dependency.to} (#{dependency.label})"
        end) ++ actual_dependency_cycle_errors(manifest, project_edges, ownership)

    if errors == [] do
      {:ok,
       %{
         dependencies: length(project_edges),
         temporary_dependencies: length(accepted_edges)
       }}
    else
      {:error, Enum.sort(errors)}
    end
  end

  defp temporary_dependency?(temporary_dependencies, source, sink, label) do
    Enum.any?(temporary_dependencies, fn dependency ->
      Map.fetch!(dependency, :from) == source and Map.fetch!(dependency, :to) == sink and
        Map.fetch!(dependency, :label) == label
    end)
  end

  defp production_file?("lib/" <> _path), do: true
  defp production_file?("apps/" <> path), do: String.contains?(path, "/lib/")
  defp production_file?(_path), do: false

  defp normalize_path(path) do
    path
    |> Path.relative_to_cwd()
    |> Path.split()
    |> Path.join()
  end

  defp read_project_manifest!({manifest_path, prefix})
       when is_binary(manifest_path) and is_binary(prefix) do
    {modules, sources} = read_manifest(manifest_path)

    if modules == [] or sources == [] do
      raise ArgumentError, "missing or empty project compiler manifest: #{manifest_path}"
    end

    %{modules: modules, sources: sources, prefix: prefix}
  end

  defp prefixed_path("", source_path), do: normalize_path(source_path)
  defp prefixed_path(prefix, source_path), do: normalize_path(Path.join(prefix, source_path))

  defp put_module_reference_edges(
         graph,
         source_path,
         referenced_modules,
         label,
         module_sources
       ) do
    Enum.reduce(referenced_modules, graph, fn module_name, graph ->
      case Map.fetch(module_sources, module_name) do
        {:ok, ^source_path} -> graph
        {:ok, sink_path} -> put_graph_edge(graph, source_path, sink_path, label)
        :error -> graph
      end
    end)
  end

  defp put_graph_edge(graph, source, sink, label) do
    graph
    |> Map.put_new(sink, %{})
    |> Map.update(source, %{sink => label}, &Map.put(&1, sink, label))
  end

  defp dependency_cycle_errors(allowed_dependencies) do
    graph =
      Map.new(@deployable_components, fn component ->
        targets =
          allowed_dependencies
          |> Map.get(component, [])
          |> Enum.filter(&MapSet.member?(@deployable_components, &1))
          |> Enum.reject(&(&1 == component))

        {component, targets}
      end)

    graph
    |> Map.keys()
    |> Enum.filter(&reaches?(graph, &1, &1, MapSet.new()))
    |> Enum.map(&"deployable component dependency cycle involves #{inspect(&1)}")
  end

  defp validate_temporary_component_cycles(manifest) do
    cycles = Map.get(manifest, :temporary_component_cycles)

    errors =
      cond do
        not is_list(cycles) ->
          ["manifest temporary component cycles must be a list"]

        true ->
          cycles
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {cycle, index} ->
            missing =
              [:components, :reason, :remove_in]
              |> Enum.reject(&(is_map(cycle) and Map.has_key?(cycle, &1)))

            components = if is_map(cycle), do: Map.get(cycle, :components), else: nil

            cond do
              missing != [] ->
                ["temporary component cycle #{index} is missing keys: #{inspect(missing)}"]

              not is_list(components) or length(components) < 2 ->
                ["temporary component cycle #{index} must contain at least two components"]

              Enum.uniq(components) != components ->
                ["temporary component cycle #{index} contains duplicate components"]

              Enum.any?(components, &(not MapSet.member?(@deployable_components, &1))) ->
                ["temporary component cycle #{index} contains a non-deployable component"]

              not nonempty_string?(Map.get(cycle, :reason)) or
                  not nonempty_string?(Map.get(cycle, :remove_in)) ->
                ["temporary component cycle #{index} has empty metadata"]

              true ->
                []
            end
          end)
      end

    duplicate_cycles =
      if is_list(cycles) do
        cycles
        |> Enum.filter(&is_map/1)
        |> Enum.map(&(Map.get(&1, :components, []) |> Enum.sort()))
        |> Enum.frequencies()
        |> Enum.flat_map(fn
          {_cycle, 1} -> []
          {cycle, _count} -> ["duplicate temporary component cycle: #{format_cycle(cycle)}"]
        end)
      else
        []
      end

    case Enum.sort(errors ++ duplicate_cycles) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp actual_dependency_cycle_errors(manifest, project_edges, ownership) do
    graph = component_graph(project_edges, ownership)
    actual_cycles = graph |> strongly_connected_components() |> MapSet.new()

    configured_cycles =
      manifest
      |> Map.fetch!(:temporary_component_cycles)
      |> Enum.map(&(Map.fetch!(&1, :components) |> Enum.sort()))
      |> MapSet.new()

    unapproved_cycles = MapSet.difference(actual_cycles, configured_cycles)
    stale_cycles = MapSet.difference(configured_cycles, actual_cycles)

    Enum.map(unapproved_cycles, fn cycle ->
      "unapproved deployable component dependency cycle: #{format_cycle(cycle)}"
    end) ++
      Enum.map(stale_cycles, fn cycle ->
        "stale temporary component dependency cycle: #{format_cycle(cycle)}"
      end)
  end

  defp component_graph(project_edges, ownership) do
    base = Map.new(@deployable_components, &{&1, MapSet.new()})

    Enum.reduce(project_edges, base, fn {source, sink, _label}, graph ->
      source_owner = Map.fetch!(ownership, source)
      sink_owner = Map.fetch!(ownership, sink)

      if source_owner != sink_owner and MapSet.member?(@deployable_components, source_owner) and
           MapSet.member?(@deployable_components, sink_owner) do
        Map.update!(graph, source_owner, &MapSet.put(&1, sink_owner))
      else
        graph
      end
    end)
  end

  defp strongly_connected_components(graph) do
    components = graph |> Map.keys() |> Enum.sort()

    components
    |> Enum.flat_map(fn component ->
      mutually_reachable =
        Enum.filter(components, fn candidate ->
          candidate != component and reachable?(graph, component, candidate, MapSet.new()) and
            reachable?(graph, candidate, component, MapSet.new())
        end)

      case mutually_reachable do
        [] -> []
        connected -> [Enum.sort([component | connected])]
      end
    end)
    |> Enum.uniq()
  end

  defp reachable?(graph, current, target, visited) do
    graph
    |> Map.get(current, MapSet.new())
    |> Enum.any?(fn next ->
      cond do
        next == target -> true
        MapSet.member?(visited, next) -> false
        true -> reachable?(graph, next, target, MapSet.put(visited, next))
      end
    end)
  end

  defp format_cycle(cycle), do: Enum.map_join(cycle, " <-> ", &Atom.to_string/1)

  defp reaches?(graph, origin, current, visited) do
    current
    |> then(&Map.get(graph, &1, []))
    |> Enum.any?(fn target ->
      cond do
        target == origin -> true
        MapSet.member?(visited, target) -> false
        true -> reaches?(graph, origin, target, MapSet.put(visited, target))
      end
    end)
  end

  defp wildcard_path?(path) when is_binary(path), do: String.contains?(path, ["*", "?", "["])
  defp wildcard_path?(_path), do: true

  defp regression_errors(label, base_items, current_items) do
    base_items = MapSet.new(base_items)

    current_items
    |> MapSet.new()
    |> MapSet.difference(base_items)
    |> Enum.map(&"new #{label} compared with the base branch: #{inspect(&1)}")
  end

  defp budget_regression_errors(base_manifest, current_manifest) do
    base_budget = Map.fetch!(base_manifest, :temporary_dependency_budget)
    current_budget = Map.fetch!(current_manifest, :temporary_dependency_budget)

    if current_budget <= base_budget do
      []
    else
      ["temporary dependency budget increased from #{base_budget} to #{current_budget}"]
    end
  end

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false
end
