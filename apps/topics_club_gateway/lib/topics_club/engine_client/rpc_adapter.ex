defmodule TopicsClub.EngineClient.RpcAdapter do
  @moduledoc false

  @behaviour TopicsClub.EngineClient.Adapter

  alias TopicsClub.EngineClient.Discovery
  alias TopicsClub.EngineClient.Reply

  @impl true
  def request(request, timeout) do
    case Discovery.engine_node() do
      {:ok, engine_node} -> call(engine_node, request, timeout)
      {:error, reason} -> Reply.error(request, reason)
    end
  end

  defp call(engine_node, request, timeout) do
    case :rpc.call(engine_node, api_module(), :dispatch, [request], timeout) do
      {:badrpc, :timeout} -> Reply.error(request, :timeout)
      {:badrpc, _reason} -> Reply.error(request, :engine_unavailable)
      reply -> reply
    end
  end

  defp api_module do
    Application.get_env(
      :topics_club_gateway,
      :engine_rpc_api_module,
      Module.concat(["TopicsClub", "Engine", "API"])
    )
  end
end
