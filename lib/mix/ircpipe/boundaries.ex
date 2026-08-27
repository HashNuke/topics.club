defmodule Mix.Ircpipe.Boundaries do
  @moduledoc false

  @type graph :: %{String.t() => %{String.t() => String.t()}}

  @dot_edge ~r/^\s*"([^"]+)" -> "([^"]+)"(?: \[label="\((compile|export)\)"\])?$/
  @dot_node ~r/^\s*"([^"]+)"$/
  @components MapSet.new([:assembly, :core, :engine, :shared, :tooling, :web])
  @deployable_components MapSet.new([:core, :engine, :shared, :web])

  def load!(path) do
    {manifest, _binding} = Code.eval_file(path)
    manifest
  end

  def tracked_files do
    ["lib/**/*.ex", "test/support/**/*.ex"]
    |> Enum.flat_map(&Path.wildcard/1)
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

  def check(manifest, graph, tracked_files \\ tracked_files()) do
    with :ok <- validate_manifest(manifest),
         {:ok, ownership} <- build_ownership(manifest, tracked_files),
         :ok <- validate_allowed_dependencies(manifest, ownership),
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

    case Enum.sort(errors ++ duplicate_edges) do
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
      ownership
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "lib/"))

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
        end)

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

  defp normalize_path(path) do
    path
    |> Path.relative_to_cwd()
    |> Path.split()
    |> Path.join()
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

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false
end
