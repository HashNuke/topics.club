defmodule Ircpipe.InternalEvent.Data do
  @moduledoc false

  @connection_schema %{
    id: :positive_integer,
    user_id: :positive_integer,
    name: :string,
    host: :string,
    port: :positive_integer,
    use_tls: :boolean,
    nickname: :string,
    status: :string,
    desired_state: :string,
    mention_notifications_enabled: :boolean,
    notification_preference_revision: :non_negative_integer
  }
  @membership_schema %{
    id: :positive_integer,
    user_id: :positive_integer,
    server_connection_id: :positive_integer,
    channel: :string,
    status: :string,
    auto_join: :boolean,
    unread_count: :non_negative_integer,
    mention_count: :non_negative_integer,
    mention_notifications_enabled: :boolean,
    notification_preference_revision: :non_negative_integer,
    joined_at: :optional_timestamp,
    left_at: :optional_timestamp
  }
  @message_schema %{
    id: :positive_integer,
    user_id: :positive_integer,
    server_connection_id: :positive_integer,
    channel_membership_id: :optional_positive_integer,
    direct_message_thread_id: :optional_positive_integer,
    nick: :optional_string,
    hostmask: :optional_string,
    sender_role: :optional_string,
    service: :optional_string,
    metadata: :map,
    body: :string,
    kind: :string,
    mentioned: :boolean,
    occurred_at: :timestamp
  }
  @thread_schema %{
    id: :positive_integer,
    user_id: :positive_integer,
    server_connection_id: :positive_integer,
    peer_nick: :string,
    account: :optional_string,
    hostmask: :optional_string,
    blocked_at: :optional_timestamp,
    closed_at: :optional_timestamp,
    unread_count: :non_negative_integer,
    mutation_revision: :non_negative_integer
  }
  @presence_user_schema %{
    nick: :string,
    nick_key: :string,
    role: :string,
    status: :string,
    hostmask: :optional_string,
    last_observed_at: :timestamp
  }

  @connection_fields Map.keys(@connection_schema)
  @membership_fields Map.keys(@membership_schema)
  @message_fields Map.keys(@message_schema)
  @thread_fields Map.keys(@thread_schema)
  @presence_user_fields Map.keys(@presence_user_schema)

  def connection(connection), do: select(connection, @connection_fields)
  def membership(membership), do: select(membership, @membership_fields)
  def message(message), do: select(message, @message_fields)
  def thread(thread), do: select(thread, @thread_fields)
  def presence_user(user), do: select(user, @presence_user_fields)
  def presence_users(users) when is_list(users), do: Enum.map(users, &presence_user/1)
  def presence_diff(diff) when is_map(diff), do: plain_value(diff)

  def valid_event_data?("buffer_left", data) do
    valid_fields?(data, %{
      connection_id: :positive_integer,
      membership_id: :optional_positive_integer,
      channel: :optional_string
    })
  end

  def valid_event_data?("buffer_read", data) do
    valid_fields?(data, %{
      connection_id: :positive_integer,
      membership_id: :optional_positive_integer,
      unread_count: :non_negative_integer,
      mention_count: :non_negative_integer
    })
  end

  def valid_event_data?("buffer_joined", data) do
    valid_fields?(data, %{
      connection: {:record, @connection_schema},
      membership: {:record, @membership_schema},
      status: :string
    })
  end

  def valid_event_data?("connection_status_changed", data) do
    valid_fields?(data, %{
      connection: {:record, @connection_schema},
      status: :string
    })
  end

  def valid_event_data?("message_committed", %{delivery: delivery} = data)
      when delivery in ["channel", "channel_attention"] do
    valid_fields?(data, %{
      delivery: {:one_of, ["channel", "channel_attention"]},
      connection: {:record, @connection_schema},
      membership: {:record, @membership_schema},
      message: {:record, @message_schema}
    })
  end

  def valid_event_data?("message_committed", %{delivery: "server"} = data) do
    valid_fields?(data, %{
      delivery: {:one_of, ["server"]},
      connection: {:record, @connection_schema},
      message: {:record, @message_schema}
    })
  end

  def valid_event_data?("message_committed", %{delivery: "direct"} = data) do
    valid_fields?(data, %{
      delivery: {:one_of, ["direct"]},
      thread: {:record, @thread_schema},
      message: {:record, @message_schema}
    })
  end

  def valid_event_data?("notification_committed", data) do
    valid_fields?(data, %{notification_id: :positive_integer})
  end

  def valid_event_data?("direct_message_thread_changed", data) do
    valid_fields?(data, %{
      thread: {:record, @thread_schema},
      connection: {:record, @connection_schema}
    })
  end

  def valid_event_data?("direct_message_thread_closed", data) do
    valid_fields?(data, %{thread: {:record, @thread_schema}})
  end

  def valid_event_data?("presence_synchronized", data) do
    valid_fields?(data, %{
      connection_id: :positive_integer,
      membership_id: :positive_integer,
      users: {:list, {:record, @presence_user_schema}}
    })
  end

  def valid_event_data?("presence_changed", data) do
    valid_fields?(data, %{
      connection_id: :positive_integer,
      membership_id: :positive_integer,
      diff: :map
    })
  end

  def valid_event_data?(_type, _data), do: false

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

  defp valid_fields?(data, schema) when is_map(data) do
    MapSet.new(Map.keys(data)) == MapSet.new(Map.keys(schema)) and
      Enum.all?(schema, fn {field, type} -> valid_type?(Map.get(data, field), type) end)
  end

  defp valid_fields?(_data, _schema), do: false

  defp valid_type?(value, :positive_integer), do: is_integer(value) and value > 0
  defp valid_type?(value, :non_negative_integer), do: is_integer(value) and value >= 0
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(nil, :optional_string), do: true
  defp valid_type?(value, :optional_string), do: is_binary(value)
  defp valid_type?(nil, :optional_positive_integer), do: true
  defp valid_type?(value, :optional_positive_integer), do: valid_type?(value, :positive_integer)
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :timestamp), do: valid_timestamp?(value)
  defp valid_type?(nil, :optional_timestamp), do: true
  defp valid_type?(value, :optional_timestamp), do: valid_timestamp?(value)
  defp valid_type?(value, {:record, schema}), do: valid_fields?(value, schema)

  defp valid_type?(value, {:list, type}) when is_list(value),
    do: Enum.all?(value, &valid_type?(&1, type))

  defp valid_type?(value, {:one_of, values}), do: value in values
  defp valid_type?(_value, _type), do: false

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false
end
