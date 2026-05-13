defmodule IrcpipeWeb.Api.ChannelController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Realtime.Event

  def create(conn, %{"connection_id" => connection_id, "channel" => channel}) do
    user = conn.assigns.current_scope.user
    connection = Chat.get_connection!(user, connection_id)

    with {:ok, membership} <- Chat.join_channel(user, connection, channel) do
      SessionSupervisor.start_session(connection)
      try_join(connection, membership.channel)

      json(conn, %{channel: channel_json(membership)})
    end
  end

  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, id)
    :ok = Chat.mark_read(user, membership)
    json(conn, %{ok: true})
  end

  def leave(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, id)

    try_part(membership)
    :ok = Chat.leave_channel(user, membership)

    json(conn, %{
      left:
        Event.buffer_left(%{
          buffer_id: "channel:#{membership.id}",
          server_connection_id: membership.server_connection_id,
          channel_membership_id: membership.id
        })
    })
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

  defp try_join(connection, channel) do
    case Session.join(connection, channel) do
      :ok -> :ok
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp try_part(membership) do
    case Session.part(membership.server_connection, membership.channel) do
      :ok -> :ok
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end
end
