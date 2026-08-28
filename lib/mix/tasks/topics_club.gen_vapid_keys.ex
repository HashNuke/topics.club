defmodule Mix.Tasks.TopicsClub.GenVapidKeys do
  use Mix.Task

  @shortdoc "Generates a VAPID keypair for Web Push"

  @impl Mix.Task
  def run(_args) do
    keys = Ircpipe.Notifications.WebPush.generate_keypair()

    Mix.shell().info("VAPID_PUBLIC_KEY=#{keys.public_key}")
    Mix.shell().info("VAPID_PRIVATE_KEY=#{keys.private_key}")
    Mix.shell().info("VAPID_SUBJECT=notifications@example.com")
  end
end
