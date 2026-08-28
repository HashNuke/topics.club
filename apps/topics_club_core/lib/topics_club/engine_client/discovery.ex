defmodule TopicsClub.EngineClient.Discovery do
  @moduledoc false

  @marker_name :topics_club_engine_marker

  def marker_name, do: @marker_name

  def whereis do
    case :global.whereis_name(@marker_name) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> {:error, :engine_unavailable}
    end
  end

  def engine_node(expected_node \\ nil) do
    case whereis() do
      {:ok, pid} -> verify_expected_node(node(pid), expected_node)
      error -> error
    end
  end

  defp verify_expected_node(engine_node, nil), do: {:ok, engine_node}
  defp verify_expected_node(engine_node, engine_node), do: {:ok, engine_node}
  defp verify_expected_node(_engine_node, _expected_node), do: {:error, :engine_unavailable}
end
