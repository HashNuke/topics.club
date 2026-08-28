defmodule Ircpipe.Chat.MessageHistory do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.DirectMessageThread
  alias Ircpipe.Chat.Message
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  @max_cursor_id 9_223_372_036_854_775_807

  def list_messages(%User{id: user_id}, membership_id, limit \\ 200) do
    Message
    |> where(
      [message],
      message.user_id == ^user_id and message.channel_membership_id == ^membership_id
    )
    |> order_by([message], desc: message.occurred_at, desc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def list_buffer_messages(user, buffer_id, opts \\ [])

  def list_buffer_messages(%User{} = user, "channel:" <> membership_id, opts) do
    membership = get_membership!(user, membership_id)
    limit = history_limit(opts)

    {query, direction} =
      Message
      |> where(
        [message],
        message.user_id == ^user.id and message.channel_membership_id == ^membership.id
      )
      |> cursor_filter(opts)

    list_cursor_messages(query, direction, limit)
  end

  def list_buffer_messages(%User{} = user, "server:" <> connection_id, opts) do
    connection = get_connection!(user, connection_id)
    limit = history_limit(opts)

    {query, direction} =
      Message
      |> where(
        [message],
        message.user_id == ^user.id and message.server_connection_id == ^connection.id and
          is_nil(message.channel_membership_id) and
          is_nil(message.direct_message_thread_id)
      )
      |> cursor_filter(opts)

    list_cursor_messages(query, direction, limit)
  end

  def list_buffer_messages(%User{} = user, "direct:" <> thread_id, opts) do
    thread = get_direct_message_thread!(user, thread_id)
    limit = history_limit(opts)

    {query, direction} =
      Message
      |> where(
        [message],
        message.user_id == ^user.id and message.direct_message_thread_id == ^thread.id
      )
      |> cursor_filter(opts)

    list_cursor_messages(query, direction, limit)
  end

  def list_buffer_messages(%User{}, _buffer_id, _opts), do: []

  def list_buffer_command_messages(%User{} = user, buffer_id, command_ids)
      when is_list(command_ids) do
    ids = command_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(50)

    query =
      case buffer_id do
        "channel:" <> membership_id ->
          membership = get_membership!(user, membership_id)

          from(message in Message,
            where:
              message.user_id == ^user.id and
                message.channel_membership_id == ^membership.id
          )

        "server:" <> connection_id ->
          connection = get_connection!(user, connection_id)

          from(message in Message,
            where:
              message.user_id == ^user.id and
                message.server_connection_id == ^connection.id and
                is_nil(message.channel_membership_id) and
                is_nil(message.direct_message_thread_id)
          )

        _invalid_buffer ->
          from(message in Message, where: false)
      end

    query
    |> where(
      [message],
      message.kind == "command" and
        fragment("?->>'command_id'", message.metadata) in ^ids and
        fragment("?->>'command_status'", message.metadata) != "result"
    )
    |> order_by([message], asc: message.occurred_at, asc: message.id)
    |> limit(50)
    |> Repo.all()
  end

  defp get_membership!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([membership], membership.user_id == ^user_id and membership.id == ^id)
    |> Repo.one!()
  end

  defp get_connection!(%User{id: user_id}, id) do
    ServerConnection
    |> where([connection], connection.user_id == ^user_id and connection.id == ^id)
    |> Repo.one!()
  end

  defp get_direct_message_thread!(%User{id: user_id}, id) do
    DirectMessageThread
    |> where([thread], thread.user_id == ^user_id and thread.id == ^id)
    |> Repo.one!()
  end

  defp history_limit(opts) do
    opts
    |> Keyword.get(:limit, 150)
    |> to_int(150)
    |> min(150)
    |> max(1)
  end

  defp cursor_filter(query, opts) do
    cond do
      opts[:after] -> cursor_filter(query, :after, opts[:after])
      opts[:before] -> cursor_filter(query, :before, opts[:before])
      true -> {query, :latest}
    end
  end

  defp cursor_filter(query, direction, cursor_id) do
    case cursor_message(query, cursor_id) do
      %Message{} = cursor ->
        {apply_cursor(query, direction, cursor), direction}

      nil ->
        {query, :latest}
    end
  end

  defp cursor_message(query, cursor_id) do
    with {:ok, id} <- parse_cursor_id(cursor_id) do
      query
      |> where([message], message.id == ^id)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  defp parse_cursor_id(id)
       when is_integer(id) and id > 0 and id <= @max_cursor_id,
       do: {:ok, id}

  defp parse_cursor_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> parse_cursor_id(integer)
      _invalid -> :error
    end
  end

  defp parse_cursor_id(_id), do: :error

  defp apply_cursor(query, :before, cursor) do
    where(
      query,
      [message],
      message.occurred_at < ^cursor.occurred_at or
        (message.occurred_at == ^cursor.occurred_at and message.id < ^cursor.id)
    )
  end

  defp apply_cursor(query, :after, cursor) do
    where(
      query,
      [message],
      message.occurred_at > ^cursor.occurred_at or
        (message.occurred_at == ^cursor.occurred_at and message.id > ^cursor.id)
    )
  end

  defp list_cursor_messages(query, :after, limit) do
    query
    |> order_by([message], asc: message.occurred_at, asc: message.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp list_cursor_messages(query, _direction, limit) do
    query
    |> order_by([message], desc: message.occurred_at, desc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp to_int(_value, default), do: default
end
