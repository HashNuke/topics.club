defmodule IrcpipeWeb.Api.MessageController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session

  def index(conn, %{"channel_id" => channel_id}) do
    user = conn.assigns.current_scope.user
    messages = Chat.list_messages(user, channel_id)
    json(conn, %{messages: Enum.map(messages, &message_json/1)})
  end

  def buffer_index(conn, %{"id" => buffer_id} = params) do
    user = conn.assigns.current_scope.user

    messages =
      Chat.list_buffer_messages(user, buffer_id,
        limit: Map.get(params, "limit", 150),
        before: Map.get(params, "before")
      )

    json(conn, %{messages: Enum.map(messages, &message_json(&1, buffer_id))})
  end

  def create(conn, %{"channel_id" => channel_id, "body" => body}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, channel_id)

    with :ok <- Session.say(membership.server_connection, membership.channel, body) do
      json(conn, %{ok: true})
    end
  end

  defp message_json(message, buffer_id \\ nil) do
    %{
      id: message.id,
      buffer_id: buffer_id,
      channel_membership_id: message.channel_membership_id,
      server_connection_id: message.server_connection_id,
      nick: message.nick,
      body: message.body,
      kind: message.kind,
      mentioned: message.mentioned,
      occurred_at: message.occurred_at
    }
  end
end
