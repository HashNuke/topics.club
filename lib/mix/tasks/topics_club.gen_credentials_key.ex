defmodule Mix.Tasks.TopicsClub.GenCredentialsKey do
  use Mix.Task

  @shortdoc "Generates an IRC credential-encryption key"

  @moduledoc """
  Generates a Base64-encoded 256-bit key for `IRC_CREDENTIALS_KEY`.

      mix topics_club.gen_credentials_key

  Store the generated value in the deployment secret manager. Existing
  encrypted credentials cannot be recovered if the key is lost.
  """

  @impl true
  def run(_args) do
    key = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
    Mix.shell().info(key)
  end
end
