defmodule IrcpipeWeb.Api.MessageController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.{MembershipLookup, MessageHistory}
  alias Ircpipe.Irc.Session
  alias Ircpipe.Realtime.Event

  def index(conn, %{"channel_id" => channel_id}) do
    user = conn.assigns.current_scope.user
    messages = MessageHistory.list_messages(user, channel_id)
    json(conn, %{messages: Enum.map(messages, &message_json/1)})
  end

  def buffer_index(conn, params) do
    user = conn.assigns.current_scope.user
    buffer_id = Map.get(params, "buffer_id") || Map.fetch!(params, "id")

    messages =
      case Map.get(params, "command_ids") do
        command_ids when is_binary(command_ids) ->
          MessageHistory.list_buffer_command_messages(
            user,
            buffer_id,
            String.split(command_ids, ",")
          )

        _command_ids ->
          MessageHistory.list_buffer_messages(user, buffer_id,
            limit: Map.get(params, "limit", 150),
            before: Map.get(params, "before"),
            after: Map.get(params, "after")
          )
      end

    json(conn, %{messages: Enum.map(messages, &message_json(&1, buffer_id))})
  end

  def create(conn, %{"channel_id" => channel_id, "body" => body}) do
    user = conn.assigns.current_scope.user
    membership = MembershipLookup.get!(user, channel_id)

    case Session.say(membership.server_connection, membership.channel, body) do
      {:ok, _message} ->
        json(conn, %{ok: true})

      {:error, %{code: code, message: message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: code, message: message})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  defp message_json(message, buffer_id \\ nil) do
    Event.message(message, buffer_id)
  end
end
