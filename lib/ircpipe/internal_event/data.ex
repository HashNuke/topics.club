defmodule Ircpipe.InternalEvent.Data do
  @moduledoc false

  @connection_fields ~w(
    id user_id name host port use_tls nickname status desired_state
    mention_notifications_enabled notification_preference_revision
  )a
  @membership_fields ~w(
    id user_id server_connection_id channel status auto_join unread_count mention_count
    mention_notifications_enabled notification_preference_revision joined_at left_at
  )a
  @message_fields ~w(
    id user_id server_connection_id channel_membership_id direct_message_thread_id nick hostmask
    sender_role service metadata body kind mentioned occurred_at
  )a
  @thread_fields ~w(
    id user_id server_connection_id peer_nick account hostmask blocked_at closed_at unread_count
    mutation_revision
  )a
  @presence_user_fields ~w(nick nick_key role status hostmask last_observed_at)a

  def connection(connection), do: select(connection, @connection_fields)
  def membership(membership), do: select(membership, @membership_fields)
  def message(message), do: select(message, @message_fields)
  def thread(thread), do: select(thread, @thread_fields)
  def presence_user(user), do: select(user, @presence_user_fields)
  def presence_users(users) when is_list(users), do: Enum.map(users, &presence_user/1)
  def presence_diff(diff) when is_map(diff), do: plain_value(diff)

  def plain_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def plain_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def plain_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, plain_value(item)} end)

  def plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  def plain_value(value), do: value

  defp select(record, fields) do
    Map.new(fields, fn field -> {field, record |> value(field) |> plain_value()} end)
  end

  defp value(record, field) do
    case Map.fetch(record, field) do
      {:ok, value} -> value
      :error -> Map.get(record, Atom.to_string(field))
    end
  end
end
