defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Commands
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if Integer.to_string(socket.assigns.current_user.id) == user_id do
      Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user_id}")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:irc_message, message}, socket) do
    push(socket, "message", message)
    {:noreply, socket}
  end

  def handle_info({:irc_mention, message}, socket) do
    push(socket, "mention", message)
    push(socket, "notification:mention", message)
    {:noreply, socket}
  end

  def handle_info({:server_status, payload}, socket) do
    push(socket, "server:status", payload)
    {:noreply, socket}
  end

  def handle_info({:presence_sync, payload}, socket) do
    push(socket, "presence:sync", payload)
    {:noreply, socket}
  end

  def handle_info({:presence_diff, payload}, socket) do
    push(socket, "presence:diff", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("command:suggest", %{"input" => input}, socket) do
    {:reply, {:ok, %{commands: Commands.suggest(input)}}, socket}
  end

  def handle_in("command:parse", %{"input" => input}, socket) do
    reply_with_command(input, socket)
  end

  def handle_in("command:run", %{"input" => input}, socket) do
    reply_with_command(input, socket)
  end

  def handle_in(
        "message:send",
        %{"buffer_id" => "channel:" <> membership_id, "body" => body} = payload,
        socket
      ) do
    user = socket.assigns.current_user
    client_message_id = Map.get(payload, "client_message_id")

    with true <- String.trim(body) != "",
         {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- say(membership, body),
         message <- latest_message(user, membership) do
      {:reply,
       {:ok,
        %{
          client_message_id: client_message_id,
          message: message_json(message, "channel:#{membership.id}")
        }}, socket}
    else
      false ->
        {:reply, {:error, %{reason: "empty_message", client_message_id: client_message_id}},
         socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), client_message_id: client_message_id}},
         socket}
    end
  end

  def handle_in("message:send", payload, socket) do
    {:reply,
     {:error,
      %{
        reason: "invalid_buffer",
        client_message_id: Map.get(payload, "client_message_id")
      }}, socket}
  end

  def handle_in("buffer:read", %{"buffer_id" => "channel:" <> membership_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- Chat.mark_read(user, membership) do
      {:reply, {:ok, %{buffer_id: "channel:#{membership.id}", unread_count: 0, mention_count: 0}},
       socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
    end
  end

  def handle_in("buffer:read", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_buffer"}}, socket}
  end

  def handle_in("channel:leave", %{"buffer_id" => "channel:" <> membership_id} = payload, socket) do
    user = socket.assigns.current_user
    reason = Map.get(payload, "reason", "leaving")

    with {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- part(membership, reason),
         :ok <- Chat.leave_channel(user, membership) do
      {:reply,
       {:ok,
        %{
          type: "buffer:left",
          buffer_id: "channel:#{membership.id}",
          server_connection_id: membership.server_connection_id,
          channel_membership_id: membership.id
        }}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: error_reason(reason)}}, socket}
    end
  end

  def handle_in("channel:leave", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_buffer"}}, socket}
  end

  def handle_in("server:disconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    :ok = SessionSupervisor.stop_session(connection)
    {:ok, connection} = Chat.update_connection_status(connection, "disconnected")

    {:reply,
     {:ok,
      %{
        type: "server:status",
        server_connection_id: connection.id,
        status: connection.status
      }}, socket}
  rescue
    Ecto.NoResultsError -> {:reply, {:error, %{reason: "invalid_server"}}, socket}
  end

  def handle_in("server:reconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    with {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      {:reply,
       {:ok,
        %{
          type: "server:status",
          server_connection_id: connection.id,
          status: "connecting"
        }}, socket}
    else
      _error -> {:reply, {:error, %{reason: "reconnect_failed"}}, socket}
    end
  rescue
    Ecto.NoResultsError -> {:reply, {:error, %{reason: "invalid_server"}}, socket}
  end

  defp reply_with_command(input, socket) do
    case Commands.parse(input) do
      {:ok, command} ->
        {:reply, {:ok, %{command: command}}, socket}

      {:error, :not_a_command} ->
        {:reply, {:error, %{reason: "not_a_command"}}, socket}

      {:error, {:unknown_command, command}} ->
        {:reply, {:error, %{reason: "unknown_command", command: command}}, socket}
    end
  end

  defp fetch_membership(user, membership_id) do
    {:ok, Chat.get_membership!(user, membership_id)}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
  end

  defp say(membership, body) do
    Session.say(membership.server_connection, membership.channel, body)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp part(membership, reason) do
    Session.part(membership.server_connection, membership.channel, reason)
  catch
    :exit, _reason -> :ok
  end

  defp latest_message(user, membership) do
    user
    |> Chat.list_messages(membership.id, 1)
    |> List.first()
  end

  defp message_json(message, buffer_id) do
    %{
      id: message.id,
      buffer_id: buffer_id,
      server_connection_id: message.server_connection_id,
      channel_membership_id: message.channel_membership_id,
      nick: message.nick,
      body: message.body,
      kind: message.kind,
      mentioned: message.mentioned,
      occurred_at: message.occurred_at
    }
  end

  defp error_reason(:invalid_buffer), do: "invalid_buffer"
  defp error_reason(:not_connected), do: "not_connected"
  defp error_reason(_reason), do: "send_failed"
end
