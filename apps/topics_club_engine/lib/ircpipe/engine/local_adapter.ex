defmodule Ircpipe.Engine.LocalAdapter do
  @moduledoc false

  @behaviour Ircpipe.EngineClient.Adapter

  @impl true
  def request(request, timeout) do
    task =
      Task.Supervisor.async_nolink(Ircpipe.Engine.RequestTaskSupervisor, fn ->
        api_module().dispatch(request)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, reply} -> reply
      {:exit, _reason} -> Ircpipe.EngineClient.Reply.error(request, :internal_error)
      nil -> Ircpipe.EngineClient.Reply.error(request, :timeout)
    end
  end

  defp api_module do
    Application.get_env(
      :topics_club_engine,
      :engine_local_api_module,
      Module.concat(["Ircpipe", "Engine", "API"])
    )
  end
end
