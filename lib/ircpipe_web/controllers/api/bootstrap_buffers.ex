defmodule IrcpipeWeb.Api.BootstrapBuffers do
  @moduledoc false

  alias Ircpipe.Irc.Session

  def for_connection(connection) do
    [
      %{
        buffer_id: server_id(connection),
        buffer_type: "server",
        server_connection_id: connection.id,
        channel_membership_id: nil,
        title: connection.host,
        subtitle: connection.name,
        status: Session.status(connection),
        unread_count: connection.unread_count,
        mention_count: connection.mention_count,
        mention_notifications_enabled: connection.mention_notifications_enabled,
        notification_preference_revision: connection.notification_preference_revision
      }
      | Enum.map(connection.direct_message_threads, &direct_message(&1, connection)) ++
          Enum.map(visible_memberships(connection), &channel(&1, connection))
    ]
  end

  def active_id(buffers) do
    channel_buffer =
      Enum.find(buffers, &(&1.buffer_type == "channel" and &1.membership_status == "joined")) ||
        Enum.find(buffers, &(&1.buffer_type == "channel"))

    buffer = channel_buffer || List.first(buffers)
    buffer && buffer.buffer_id
  end

  def server_id(connection), do: "server:#{connection.id}"
  def channel_id(membership), do: "channel:#{membership.id}"
  def direct_message_id(thread), do: "direct:#{thread.id}"

  def visible_memberships(connection) do
    Enum.filter(connection.channel_memberships, &(&1.status in ["pending", "joined"]))
  end

  defp direct_message(thread, connection) do
    %{
      buffer_id: direct_message_id(thread),
      buffer_type: "direct_message",
      server_connection_id: connection.id,
      channel_membership_id: nil,
      direct_message_thread_id: thread.id,
      direct_message_revision: thread.mutation_revision,
      title: thread.peer_nick,
      subtitle: "on #{connection.host}",
      status: Session.status(connection),
      unread_count: thread.unread_count,
      mention_count: 0,
      peer_nick: thread.peer_nick,
      account: thread.account,
      hostmask: thread.hostmask,
      blocked: not is_nil(thread.blocked_at),
      closed_at: thread.closed_at
    }
  end

  defp channel(membership, connection) do
    %{
      buffer_id: channel_id(membership),
      buffer_type: "channel",
      server_connection_id: connection.id,
      channel_membership_id: membership.id,
      title: membership.channel,
      subtitle: "on #{connection.host}",
      status: Session.status(connection),
      membership_status: membership.status,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end
end
