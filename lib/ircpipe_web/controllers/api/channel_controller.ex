defmodule IrcpipeWeb.Api.ChannelController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor

  def create(conn, %{"connection_id" => connection_id, "channel" => channel}) do
    user = conn.assigns.current_scope.user
    connection = Chat.get_connection!(user, connection_id)

    with {:ok, membership} <- Chat.join_channel(user, connection, channel),
         {:ok, _pid} <- SessionSupervisor.start_session(connection),
         :ok <- Session.join(connection, membership.channel) do
      json(conn, %{channel: channel_json(membership)})
    end
  end

  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, id)
    :ok = Chat.mark_read(user, membership)
    json(conn, %{ok: true})
  end

  defp channel_json(channel) do
    %{
      id: channel.id,
      connection_id: channel.server_connection_id,
      channel: channel.channel,
      unread_count: channel.unread_count,
      mention_count: channel.mention_count
    }
  end
end
