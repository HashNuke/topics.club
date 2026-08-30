defmodule Mix.Tasks.TopicsClub.GenVapidKeys do
  use Mix.Task

  @shortdoc "Generates a VAPID keypair for Web Push"

  @impl Mix.Task
  def run(_args) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    Mix.shell().info("VAPID_PUBLIC_KEY=#{Base.url_encode64(public_key, padding: false)}")
    Mix.shell().info("VAPID_PRIVATE_KEY=#{Base.url_encode64(private_key, padding: false)}")
    Mix.shell().info("VAPID_SUBJECT=notifications@example.com")
  end
end
