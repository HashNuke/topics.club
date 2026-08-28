defmodule TopicsClub.Engine.Diagnostics do
  @moduledoc false

  alias TopicsClub.Engine.Marker
  alias TopicsClub.EngineClient.Contract
  alias TopicsClub.Irc.SessionSupervisor

  def snapshot do
    %{
      active_sessions: active_sessions(),
      engine_node: Atom.to_string(node()),
      marker: Marker.status(),
      operations: Contract.operations(),
      protocol_version: Contract.version()
    }
  end

  defp active_sessions do
    SessionSupervisor
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  catch
    :exit, _reason -> 0
  end
end
