defmodule TopicsClub.Wirekeeper.DocumentationTest do
  use ExUnit.Case, async: true

  @published_modules [
    TopicsClub.Wirekeeper,
    TopicsClub.Wirekeeper.ProtocolAdapter,
    TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive,
    TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough
  ]

  test "every published module and API entry has compiled documentation" do
    assert Enum.sort(published_wirekeeper_modules()) == Enum.sort(@published_modules)

    undocumented =
      Enum.flat_map(@published_modules, fn module ->
        {:docs_v1, _annotation, :elixir, _format, module_doc, _metadata, entries} =
          Code.fetch_docs(module)

        module_issues = if documented?(module_doc), do: [], else: [{module, :module}]

        entry_issues =
          for {{kind, name, arity}, _annotation, _signature, docs, _metadata} <- entries,
              kind in [:function, :callback, :type],
              name != :__struct__,
              not documented?(docs) do
            {module, {kind, name, arity}}
          end

        module_issues ++ entry_issues
      end)

    assert undocumented == []
  end

  defp published_wirekeeper_modules do
    {:ok, modules} = :application.get_key(:topics_club_wirekeeper, :modules)

    Enum.filter(modules, fn module ->
      module
      |> Code.fetch_docs()
      |> case do
        {:docs_v1, _annotation, :elixir, _format, docs, _metadata, _entries} ->
          documented?(docs)

        _unavailable ->
          false
      end
    end)
  end

  defp documented?(%{"en" => docs}) when is_binary(docs), do: String.trim(docs) != ""
  defp documented?(_docs), do: false
end
