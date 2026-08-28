defmodule IrcpipeWeb.UserChannel.MessageHandler do
  @moduledoc false

  alias Ircpipe.EngineClient
  alias Ircpipe.Realtime.Event
  alias IrcpipeWeb.UserChannel.BufferResolver
  alias IrcpipeWeb.UserChannel.ErrorResponse
  alias IrcpipeWeb.UserChannel.Reply

  def send_message(
        %{"buffer_id" => "channel:" <> membership_id, "body" => body} = payload,
        socket
      )
      when is_binary(body) do
    user = socket.assigns.current_user
    client_message_id = Map.get(payload, "client_message_id")

    with true <- String.trim(body) != "",
         {:ok, membership} <- BufferResolver.membership(user, membership_id) do
      case say(user, membership, body) do
        {:ok, %{message: message}} ->
          Reply.ok(socket, %{
            client_message_id: client_message_id,
            message: Event.message(message, "channel:#{membership.id}")
          })

        {:error, reason} ->
          Reply.error(socket, %{
            reason: ErrorResponse.reason(reason),
            client_message_id: client_message_id
          })
      end
    else
      false ->
        Reply.error(socket, %{reason: "empty_message", client_message_id: client_message_id})

      {:error, reason} ->
        Reply.error(socket, %{
          reason: ErrorResponse.reason(reason),
          client_message_id: client_message_id
        })
    end
  end

  def send_message(
        %{"buffer_id" => "direct:" <> thread_id, "body" => body} = payload,
        socket
      )
      when is_binary(body) do
    user = socket.assigns.current_user
    client_message_id = Map.get(payload, "client_message_id")

    with true <- String.trim(body) != "",
         {:ok, thread} <- BufferResolver.direct_message_thread(user, thread_id),
         {:ok, %{thread: sent_thread, message: message}} <- direct_message(user, thread, body) do
      Reply.ok(socket, %{
        client_message_id: client_message_id,
        message:
          Event.message(message, "direct:#{sent_thread.id}", %{
            peer_nick: sent_thread.peer_nick
          })
      })
    else
      false ->
        Reply.error(socket, %{reason: "empty_message", client_message_id: client_message_id})

      {:error, reason} ->
        Reply.error(socket, %{
          reason: ErrorResponse.reason(reason),
          client_message_id: client_message_id
        })
    end
  end

  def send_message(%{"body" => body} = payload, socket) when is_binary(body) do
    Reply.error(socket, %{
      reason: "invalid_buffer",
      client_message_id: Map.get(payload, "client_message_id")
    })
  end

  def send_message(payload, socket) when is_map(payload) do
    Reply.error(socket, %{
      reason: "invalid_arguments",
      client_message_id: Map.get(payload, "client_message_id")
    })
  end

  def send_message(_payload, socket) do
    Reply.error(socket, %{reason: "invalid_arguments"})
  end

  defp say(user, membership, body),
    do:
      EngineClient.send_channel_message(
        user.id,
        membership.server_connection_id,
        membership.id,
        body
      )

  defp direct_message(user, thread, body) do
    if not is_nil(thread.closed_at) or String.starts_with?(thread.peer_key, "archived:") do
      {:error, :direct_message_closed}
    else
      EngineClient.send_direct_message(
        user.id,
        thread.server_connection_id,
        thread.id,
        body
      )
    end
  end
end
