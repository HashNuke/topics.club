defmodule Mix.Tasks.TopicsClub.RefreshDiscovery do
  use Mix.Task

  @shortdoc "Refreshes due IRC discovery data"

  @moduledoc """
  Refreshes due IRC discovery data from Netsplit and IRC `LIST` replies.

      mix topics_club.refresh_discovery

  The network catalog is refreshed after seven days. Server-channel catalogs
  are refreshed after 24 hours.
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case Ircpipe.Discovery.Refresher.run() do
      :ok -> Mix.shell().info("IRC discovery data is up to date.")
      {:error, reason} -> Mix.raise("IRC discovery refresh failed: #{inspect(reason)}")
    end
  end
end
