defmodule TopicsClub.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: TopicsClub.Vault
end
