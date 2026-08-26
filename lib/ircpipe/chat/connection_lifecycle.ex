defmodule Ircpipe.Chat.ConnectionLifecycle do
  @moduledoc false

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Realtime.Event
  alias Ircpipe.Repo

  def update_status(%ServerConnection{} = connection, status) do
    connection
    |> ServerConnection.changeset(%{
      status: status,
      last_connected_at: if(status == "connected", do: DateTime.utc_now(:second))
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_status(updated, updated.status)
      _other -> :ok
    end)
  end

  def touch_connected(%ServerConnection{} = connection) do
    connection
    |> Ecto.Changeset.change(last_connected_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def update_nickname(%ServerConnection{} = connection, nickname, status \\ nil) do
    connection
    |> ServerConnection.changeset(%{nickname: nickname})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_status(updated, status || updated.status)
      _other -> :ok
    end)
  end

  def broadcast_status(%ServerConnection{} = connection, status) do
    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:server_status, Event.server_status(connection, status)}
    )
  end
end
