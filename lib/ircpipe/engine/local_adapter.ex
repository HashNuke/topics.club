defmodule Ircpipe.Engine.LocalAdapter do
  @moduledoc false

  @behaviour Ircpipe.EngineClient.Adapter

  @impl true
  def request(request, _timeout) do
    api_module().dispatch(request)
  end

  defp api_module do
    Application.get_env(
      :ircpipe,
      :engine_local_api_module,
      Module.concat(["Ircpipe", "Engine", "API"])
    )
  end
end
