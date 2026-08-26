defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.Accounts.Scope
  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Realtime.Event
  alias IrcpipeWeb.UserChannel.BufferResolver
  alias IrcpipeWeb.UserChannel.ChannelDirectory
  alias IrcpipeWeb.UserChannel.CommandHandler
  alias IrcpipeWeb.UserChannel.ErrorResponse
  alias IrcpipeWeb.UserChannel.MessageHandler
  alias IrcpipeWeb.UserChannel.Reply

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if authorized_session?(socket, user_id) do
      Accounts.touch_last_seen(socket.assigns.current_user)
      Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user_id}")
      send(self(), {:sync_server_statuses, socket.assigns.current_user})
      schedule_session_expiration(socket)

      {:ok,
       %{
         server_time: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
         missed_event_cursor: nil
       }, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_info(:validate_auth_session, socket) do
    if authorized_session?(socket, Integer.to_string(socket.assigns.current_user.id)) do
      schedule_session_expiration(socket)
      {:noreply, socket}
    else
      IrcpipeWeb.Endpoint.broadcast(socket.assigns.session_socket_id, "disconnect", %{})
      {:stop, :normal, socket}
    end
  end

  @impl true
  def handle_info({:irc_message, message}, socket) do
    push(socket, "message", message)
    {:noreply, socket}
  end

  def handle_info({:buffer_message, message}, socket) do
    push(socket, "buffer:message", message)
    {:noreply, socket}
  end

  def handle_info({:buffer_error, message}, socket) do
    push(socket, "buffer:error", message)
    {:noreply, socket}
  end

  def handle_info({:buffer_system, message}, socket) do
    push(socket, "buffer:system", message)
    {:noreply, socket}
  end

  def handle_info({:direct_message_thread, payload}, socket) do
    push(socket, "direct_message:thread", payload)
    {:noreply, socket}
  end

  def handle_info({:direct_message_closed, payload}, socket) do
    push(socket, "direct_message:closed", payload)
    {:noreply, socket}
  end

  def handle_info({:notification_preference, payload}, socket) do
    push(socket, "notification:preference", payload)
    {:noreply, socket}
  end

  def handle_info({:server_status, payload}, socket) do
    push(socket, "server:status", payload)
    {:noreply, socket}
  end

  def handle_info({:sync_server_statuses, user}, socket) do
    Enum.each(Chat.list_connections(user), fn connection ->
      push(socket, "server:status", Event.server_status(connection, Session.status(connection)))
    end)

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

  def handle_info({:buffer_left, payload}, socket) do
    push(socket, "buffer:left", payload)
    {:noreply, socket}
  end

  def handle_info({:buffer_read, payload}, socket) do
    push(socket, "buffer:read", payload)
    {:noreply, socket}
  end

  def handle_info({:buffer_joined, payload}, socket) do
    push(socket, "buffer:joined", payload)
    {:noreply, socket}
  end

  defp authorized_session?(socket, user_id) do
    with true <- Integer.to_string(socket.assigns.current_user.id) == user_id,
         token when is_binary(token) <- socket.assigns[:session_token],
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      user.id == socket.assigns.current_user.id
    else
      _ -> false
    end
  end

  defp schedule_session_expiration(socket) do
    expires_at =
      socket.assigns[:session_token_inserted_at]
      |> Kernel.||(DateTime.utc_now(:second))
      |> UserToken.session_token_expires_at()

    delay = max(DateTime.diff(expires_at, DateTime.utc_now(:millisecond), :millisecond), 0)
    Process.send_after(self(), :validate_auth_session, delay)
  end

  @impl true
  def handle_in("command:suggest", %{"input" => input}, socket) do
    CommandHandler.suggest(input, socket)
  end

  def handle_in("command:parse", %{"input" => input}, socket) do
    CommandHandler.parse(input, socket)
  end

  def handle_in("command:run", %{"input" => _input} = payload, socket) do
    CommandHandler.run(payload, socket)
  end

  def handle_in("message:send", payload, socket) do
    MessageHandler.send_message(payload, socket)
  end

  def handle_in("buffer:read", %{"buffer_id" => "channel:" <> membership_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, membership} <- BufferResolver.membership(user, membership_id),
         :ok <- Chat.mark_read(user, membership) do
      Reply.ok(socket, %{buffer_id: "channel:#{membership.id}", unread_count: 0, mention_count: 0})
    else
      {:error, reason} -> Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  end

  def handle_in("buffer:read", %{"buffer_id" => "server:" <> connection_id}, socket) do
    user = socket.assigns.current_user

    connection = Chat.get_connection!(user, connection_id)
    :ok = Chat.mark_read(user, connection)

    Reply.ok(socket, %{buffer_id: "server:#{connection.id}", unread_count: 0, mention_count: 0})
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "invalid_server"})
  end

  def handle_in("buffer:read", %{"buffer_id" => "direct:" <> thread_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, thread} <- BufferResolver.direct_message_thread(user, thread_id),
         {:ok, updated} <- Chat.mark_direct_message_read(Scope.for_user(user), thread.id) do
      Reply.ok(socket, Event.direct_message_thread(updated, updated.server_connection))
    else
      {:error, reason} -> Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  end

  def handle_in("buffer:read", _payload, socket) do
    Reply.error(socket, %{reason: "invalid_buffer"})
  end

  def handle_in(
        "direct_message:block",
        %{"buffer_id" => "direct:" <> thread_id, "blocked" => blocked?},
        socket
      )
      when is_boolean(blocked?) do
    user = socket.assigns.current_user

    with {:ok, thread} <- BufferResolver.direct_message_thread(user, thread_id),
         {:ok, updated} <-
           Chat.set_direct_message_blocked(Scope.for_user(user), thread.id, blocked?) do
      Reply.ok(socket, Event.direct_message_thread(updated, updated.server_connection))
    else
      {:error, reason} -> Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  end

  def handle_in("direct_message:block", _payload, socket) do
    Reply.error(socket, %{reason: "invalid_direct_message"})
  end

  def handle_in(
        "direct_message:close",
        %{"buffer_id" => "direct:" <> thread_id},
        socket
      ) do
    user = socket.assigns.current_user

    with {:ok, thread} <- BufferResolver.direct_message_thread(user, thread_id),
         {:ok, closed} <- Chat.close_direct_message_thread(Scope.for_user(user), thread.id) do
      Reply.ok(socket, Event.direct_message_closed(closed))
    else
      {:error, reason} -> Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  end

  def handle_in("direct_message:close", _payload, socket) do
    Reply.error(socket, %{reason: "invalid_direct_message"})
  end

  def handle_in("channel:leave", %{"buffer_id" => "channel:" <> membership_id} = payload, socket) do
    user = socket.assigns.current_user
    reason = Map.get(payload, "reason", "leaving")

    with {:ok, membership} <- BufferResolver.membership(user, membership_id),
         :ok <- part(membership, reason) do
      Reply.ok(
        socket,
        %{
          status: "sent",
          buffer_id: "channel:#{membership.id}",
          server_connection_id: membership.server_connection_id,
          channel_membership_id: membership.id
        }
      )
    else
      {:error, reason} -> Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  end

  def handle_in("channel:leave", _payload, socket) do
    Reply.error(socket, %{reason: "invalid_buffer"})
  end

  def handle_in("server:list", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    case ChannelDirectory.fetch(connection) do
      {:ok, directory} ->
        Reply.ok(socket, %{directory: directory})

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason)})
    end
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:list", _payload, socket) do
    Reply.error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:disconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    :ok = SessionSupervisor.stop_session(connection)

    Reply.ok(socket, Event.server_status(connection, Session.status(connection)))
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:reconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    with {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      Reply.ok(socket, Event.server_status(connection, Session.status(connection)))
    else
      _error -> Reply.error(socket, %{reason: "reconnect_failed"})
    end
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "invalid_server"})
  end

  defp part(membership, reason) do
    Session.part(membership.server_connection, membership.channel, reason)
  catch
    :exit, _reason -> {:error, :not_connected}
  end
end
