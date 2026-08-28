defmodule Ircpipe.Chat.Topics do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{ConnectionAttributes, Connections, ServerConnection, Topic}
  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def list do
    Topic
    |> order_by([topic], asc: topic.sort_order, asc: topic.name)
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(Topic, id)

  def join(%User{} = user, %Topic{} = topic) do
    Repo.transaction(fn ->
      {:ok, connection} =
        Connections.create_or_get(user, %{
          "name" => topic.server_host,
          "host" => topic.server_host,
          "port" => topic.server_port,
          "use_tls" => topic.use_tls,
          "nickname" => ConnectionAttributes.default_nick(user)
        })

      %{connection: ensure_valid_nick(connection, user), topic: topic}
    end)
  end

  defp ensure_valid_nick(%ServerConnection{} = connection, %User{} = user) do
    if Identifier.valid_nick?(connection.nickname) do
      connection
    else
      {:ok, connection} =
        connection
        |> ServerConnection.changeset(%{
          nickname: ConnectionAttributes.default_nick(user),
          status: "disconnected"
        })
        |> Repo.update()

      connection
    end
  end
end
