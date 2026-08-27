defmodule Ircpipe.Chat.ServerConnectionLock do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  def lock!(connection_id) when is_integer(connection_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "server connection row locks require an active database transaction"
    end

    ServerConnection
    |> where([connection], connection.id == ^connection_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end
end
