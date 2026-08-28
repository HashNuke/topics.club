defmodule TopicsClub.Engine.Serialization do
  @moduledoc false

  alias TopicsClub.Chat.ChannelMembership
  alias TopicsClub.Chat.DirectMessageThread
  alias TopicsClub.Chat.Message
  alias TopicsClub.Chat.ServerConnection
  alias Ircxd.Client.Info

  def connection(%ServerConnection{} = connection) do
    %{
      id: connection.id,
      user_id: connection.user_id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: connection.status,
      desired_state: connection.desired_state,
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision,
      deleting: connection.deleting
    }
  end

  def membership(%ChannelMembership{} = membership) do
    %{
      id: membership.id,
      user_id: membership.user_id,
      server_connection_id: membership.server_connection_id,
      channel: membership.channel,
      status: membership.status,
      auto_join: membership.auto_join,
      joined_at: timestamp(membership.joined_at),
      left_at: timestamp(membership.left_at),
      last_error: membership.last_error,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end

  def message(%Message{} = message) do
    %{
      id: message.id,
      user_id: message.user_id,
      server_connection_id: message.server_connection_id,
      channel_membership_id: message.channel_membership_id,
      direct_message_thread_id: message.direct_message_thread_id,
      kind: message.kind,
      nick: message.nick,
      hostmask: message.hostmask,
      sender_role: message.sender_role,
      service: message.service,
      metadata: plain_value(message.metadata || %{}),
      body: message.body,
      mentioned: message.mentioned,
      occurred_at: timestamp(message.occurred_at)
    }
  end

  def direct_message_thread(%DirectMessageThread{} = thread) do
    %{
      id: thread.id,
      user_id: thread.user_id,
      server_connection_id: thread.server_connection_id,
      peer_nick: thread.peer_nick,
      peer_key: thread.peer_key,
      account: thread.account,
      hostmask: thread.hostmask,
      closed_at: timestamp(thread.closed_at),
      blocked_at: timestamp(thread.blocked_at),
      unread_count: thread.unread_count,
      mutation_revision: thread.mutation_revision
    }
  end

  def connection_info(%Info{} = info) do
    %{
      status: info.status,
      connected?: info.connected?,
      registered?: info.registered?,
      host: info.host,
      port: info.port,
      tls?: info.tls?,
      transport: info.transport,
      desired_nick: info.desired_nick,
      current_nick: info.current_nick,
      available_caps: plain_value(info.available_caps),
      active_caps: info.active_caps |> MapSet.to_list() |> Enum.sort(),
      isupport: plain_value(info.isupport),
      casemapping: info.casemapping
    }
  end

  def command_result(result) when is_map(result) do
    result
    |> Map.take([:command_id, :status, :command, :display])
    |> Map.put(
      :channel_messages,
      result |> Map.get(:channel_messages, []) |> Enum.map(&message/1)
    )
    |> Map.put(
      :direct_messages,
      result
      |> Map.get(:direct_messages, [])
      |> Enum.map(fn %{thread: thread, message: message} ->
        %{thread: direct_message_thread(thread), message: message(message)}
      end)
    )
  end

  def error_details(%{code: code} = error) when is_binary(code) do
    error
    |> Map.take([:code, :command, :message, :usage])
    |> plain_value()
  end

  def error_details(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  def error_details(_reason), do: %{}

  defp plain_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp plain_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp plain_value(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.map(&plain_value/1)

  defp plain_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, plain_value(item)} end)
  end

  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)

  defp plain_value(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value) or is_atom(value),
       do: value

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
end
