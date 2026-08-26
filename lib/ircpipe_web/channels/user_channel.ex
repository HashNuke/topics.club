defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.Accounts.Scope
  alias Ircpipe.Chat
  alias Ircpipe.Irc.Commands
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Realtime.Event

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

  def handle_info({:irc_mention, message}, socket) do
    push(socket, "notification:mention", message)
    {:noreply, socket}
  end

  def handle_info({:direct_message_notification, message}, socket) do
    push(socket, "notification:direct_message", message)
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
    reply_ok(socket, %{commands: Commands.suggest(input)})
  end

  def handle_in("command:parse", %{"input" => input}, socket) do
    reply_with_command(input, socket)
  end

  def handle_in("command:run", %{"input" => input} = payload, socket) do
    command_id = Map.get(payload, "command_id") || Ecto.UUID.generate()
    socket = assign(socket, :command_id, command_id)

    result =
      case Commands.parse(input) do
        {:ok, command} ->
          run_command(command, socket.assigns.current_user, Map.get(payload, "buffer_id"), socket)

        {:error, :not_a_command} ->
          reply_error(socket, %{reason: "not_a_command"})

        {:error, {:unknown_command, command}} ->
          reply_error(socket, %{reason: "unknown_command", command: command})
      end

    put_reply_command_id(result, command_id)
  end

  def handle_in(
        "message:send",
        %{"buffer_id" => "channel:" <> membership_id, "body" => body} = payload,
        socket
      ) do
    user = socket.assigns.current_user
    client_message_id = Map.get(payload, "client_message_id")

    with true <- String.trim(body) != "",
         {:ok, membership} <- fetch_membership(user, membership_id) do
      case say(membership, body) do
        :ok ->
          message = latest_message(user, membership)

          reply_ok(socket, %{
            client_message_id: client_message_id,
            message: Event.message(message, "channel:#{membership.id}")
          })

        {:error, reason} ->
          Chat.record_channel_system_message(
            membership.server_connection,
            membership.channel,
            "error",
            nil,
            send_error_body(reason)
          )

          reply_error(socket, %{
            reason: error_reason(reason),
            client_message_id: client_message_id
          })
      end
    else
      false ->
        reply_error(socket, %{reason: "empty_message", client_message_id: client_message_id})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), client_message_id: client_message_id})
    end
  end

  def handle_in(
        "message:send",
        %{"buffer_id" => "direct:" <> thread_id, "body" => body} = payload,
        socket
      ) do
    user = socket.assigns.current_user
    client_message_id = Map.get(payload, "client_message_id")

    with true <- String.trim(body) != "",
         {:ok, thread} <- fetch_direct_message_thread(user, thread_id),
         {:ok, %{thread: sent_thread, message: message}} <- direct_message(thread, body) do
      reply_ok(socket, %{
        client_message_id: client_message_id,
        message:
          Event.message(message, "direct:#{sent_thread.id}", %{
            peer_nick: sent_thread.peer_nick
          })
      })
    else
      false ->
        reply_error(socket, %{reason: "empty_message", client_message_id: client_message_id})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), client_message_id: client_message_id})
    end
  end

  def handle_in("message:send", payload, socket) do
    reply_error(socket, %{
      reason: "invalid_buffer",
      client_message_id: Map.get(payload, "client_message_id")
    })
  end

  def handle_in("buffer:read", %{"buffer_id" => "channel:" <> membership_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- Chat.mark_read(user, membership) do
      reply_ok(socket, %{buffer_id: "channel:#{membership.id}", unread_count: 0, mention_count: 0})
    else
      {:error, reason} -> reply_error(socket, %{reason: error_reason(reason)})
    end
  end

  def handle_in("buffer:read", %{"buffer_id" => "server:" <> connection_id}, socket) do
    user = socket.assigns.current_user

    connection = Chat.get_connection!(user, connection_id)
    :ok = Chat.mark_read(user, connection)

    reply_ok(socket, %{buffer_id: "server:#{connection.id}", unread_count: 0, mention_count: 0})
  rescue
    Ecto.NoResultsError -> reply_error(socket, %{reason: "invalid_server"})
  end

  def handle_in("buffer:read", %{"buffer_id" => "direct:" <> thread_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, thread} <- fetch_direct_message_thread(user, thread_id),
         {:ok, updated} <- Chat.mark_direct_message_read(Scope.for_user(user), thread.id) do
      reply_ok(socket, Event.direct_message_thread(updated, updated.server_connection))
    else
      {:error, reason} -> reply_error(socket, %{reason: error_reason(reason)})
    end
  end

  def handle_in("buffer:read", _payload, socket) do
    reply_error(socket, %{reason: "invalid_buffer"})
  end

  def handle_in(
        "direct_message:block",
        %{"buffer_id" => "direct:" <> thread_id, "blocked" => blocked?},
        socket
      )
      when is_boolean(blocked?) do
    user = socket.assigns.current_user

    with {:ok, thread} <- fetch_direct_message_thread(user, thread_id),
         {:ok, updated} <-
           Chat.set_direct_message_blocked(Scope.for_user(user), thread.id, blocked?) do
      reply_ok(socket, Event.direct_message_thread(updated, updated.server_connection))
    else
      {:error, reason} -> reply_error(socket, %{reason: error_reason(reason)})
    end
  end

  def handle_in("direct_message:block", _payload, socket) do
    reply_error(socket, %{reason: "invalid_direct_message"})
  end

  def handle_in(
        "direct_message:close",
        %{"buffer_id" => "direct:" <> thread_id},
        socket
      ) do
    user = socket.assigns.current_user

    with {:ok, thread} <- fetch_direct_message_thread(user, thread_id),
         {:ok, closed} <- Chat.close_direct_message_thread(Scope.for_user(user), thread.id) do
      reply_ok(socket, %{
        buffer_id: "direct:#{thread.id}",
        direct_message_thread_id: thread.id,
        server_connection_id: thread.server_connection_id,
        revision: closed.mutation_revision
      })
    else
      {:error, reason} -> reply_error(socket, %{reason: error_reason(reason)})
    end
  end

  def handle_in("direct_message:close", _payload, socket) do
    reply_error(socket, %{reason: "invalid_direct_message"})
  end

  def handle_in("channel:leave", %{"buffer_id" => "channel:" <> membership_id} = payload, socket) do
    user = socket.assigns.current_user
    reason = Map.get(payload, "reason", "leaving")

    with {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- part(membership, reason) do
      reply_ok(
        socket,
        %{
          status: "sent",
          buffer_id: "channel:#{membership.id}",
          server_connection_id: membership.server_connection_id,
          channel_membership_id: membership.id
        }
      )
    else
      {:error, reason} -> reply_error(socket, %{reason: error_reason(reason)})
    end
  end

  def handle_in("channel:leave", _payload, socket) do
    reply_error(socket, %{reason: "invalid_buffer"})
  end

  def handle_in("server:list", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    case list_channels(connection) do
      {:ok, channels} ->
        reply_ok(socket, %{directory: channel_directory(connection, channels)})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason)})
    end
  rescue
    Ecto.NoResultsError -> reply_error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:list", _payload, socket) do
    reply_error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:disconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    :ok = SessionSupervisor.stop_session(connection)

    reply_ok(socket, Event.server_status(connection, Session.status(connection)))
  rescue
    Ecto.NoResultsError -> reply_error(socket, %{reason: "invalid_server"})
  end

  def handle_in("server:reconnect", %{"server_connection_id" => connection_id}, socket) do
    user = socket.assigns.current_user
    connection = Chat.get_connection!(user, connection_id)

    with {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      reply_ok(socket, Event.server_status(connection, Session.status(connection)))
    else
      _error -> reply_error(socket, %{reason: "reconnect_failed"})
    end
  rescue
    Ecto.NoResultsError -> reply_error(socket, %{reason: "invalid_server"})
  end

  defp reply_with_command(input, socket) do
    case Commands.parse(input) do
      {:ok, command} ->
        reply_ok(socket, %{command: command})

      {:error, :not_a_command} ->
        reply_error(socket, %{reason: "not_a_command"})

      {:error, {:unknown_command, command}} ->
        reply_error(socket, %{reason: "unknown_command", command: command})
    end
  end

  defp run_command(command, _user, nil, socket),
    do: reply_error(socket, %{reason: "invalid_buffer", command: command})

  defp run_command(%{name: "join", args: [channel]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, result} <- execute_intent(connection, "JOIN #{channel}", buffer_id, socket),
         {:ok, membership} <- membership_for_channel(user, connection, channel) do
      reply_ok(
        socket,
        result
        |> Map.put(:command, command)
        |> Map.put(:buffer_id, "channel:#{membership.id}")
      )
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: "list", args: []} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, channels} <- list_channels(connection) do
      reply_ok(socket, %{
        command: command,
        directory: channel_directory(connection, channels)
      })
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: name, args: args} = command, user, buffer_id, socket)
       when name in ["part", "leave"] do
    with {:ok, membership} <- membership_from_part_command(user, buffer_id, args),
         {:ok, result} <-
           execute_intent(
             membership.server_connection,
             "PART #{membership.channel} :leaving",
             "channel:#{membership.id}",
             socket
           ) do
      reply_ok(
        socket,
        result
        |> Map.put(:command, command)
        |> Map.put(:buffer_id, "channel:#{membership.id}")
      )
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(
         %{name: "me", args: [body]} = command,
         user,
         "channel:" <> membership_id,
         socket
       ) do
    with {:ok, membership} <- fetch_membership(user, membership_id),
         {:ok, result} <-
           execute_intent(
             membership.server_connection,
             "PRIVMSG #{membership.channel} :\x01ACTION #{body}\x01",
             "channel:#{membership.id}",
             socket
           ),
         message <- latest_message(user, membership) do
      reply_ok(socket, %{
        command: command,
        command_id: result.command_id,
        status: result.status,
        message: Event.message(message, "channel:#{membership.id}")
      })
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: "msg", args: [target, body]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, client_info} <- session_connection_info(connection),
         true <- Chat.valid_nick?(target, Map.get(client_info, :isupport, %{})),
         {:ok, result} <-
           resolve_and_execute_intent(
             connection,
             client_info,
             "PRIVMSG #{target} :#{body}",
             "server:#{connection.id}",
             socket
           ),
         [%{thread: thread, message: message}] <- result.direct_messages do
      event = Event.direct_message_thread(thread, connection)

      reply_ok(
        socket,
        Map.merge(event, %{
          command: command,
          command_id: result.command_id,
          status: result.status,
          message: Event.message(message, "direct:#{thread.id}", %{peer_nick: thread.peer_nick})
        })
      )
    else
      false ->
        reply_error(socket, %{reason: "invalid_nick", command: command})

      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})

      [] ->
        reply_error(socket, %{reason: "send_failed", command: command})
    end
  rescue
    Ecto.NoResultsError -> reply_error(socket, %{reason: "send_failed", command: command})
  end

  defp run_command(%{name: "nick", args: [nick]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, result} <- execute_intent(connection, "NICK #{nick}", buffer_id, socket) do
      reply_ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: "topic", args: [channel]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, membership} <- membership_for_channel(user, connection, channel),
         {:ok, client_info} <- session_connection_info(connection),
         {:ok, intent} <- CommandRegistry.resolve("TOPIC #{membership.channel}", client_info),
         {:ok, result} <-
           Session.execute(
             connection,
             intent,
             socket.assigns.command_id,
             "channel:#{membership.id}"
           ) do
      reply_ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: "topic", args: [channel, topic]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, membership} <- membership_for_channel(user, connection, channel),
         {:ok, result} <-
           execute_intent(
             connection,
             "TOPIC #{membership.channel} :#{topic}",
             "channel:#{membership.id}",
             socket
           ) do
      reply_ok(
        socket,
        result
        |> Map.put(:command, command)
        |> Map.put(:buffer_id, "channel:#{membership.id}")
      )
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(%{name: "quote", args: [line]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, client_info} <- session_connection_info(connection),
         {:ok, intent} <- CommandRegistry.resolve(line, client_info),
         {:ok, result} <-
           Session.execute(connection, intent, socket.assigns.command_id, buffer_id) do
      reply_ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: code} = error} ->
        reply_error(socket, %{reason: code, error: error, command: command})

      {:error, reason} ->
        reply_error(socket, %{reason: error_reason(reason), command: command})
    end
  end

  defp run_command(command, _user, _buffer_id, socket) do
    reply_error(socket, %{reason: "invalid_command_args", command: command})
  end

  defp reply_ok(socket, payload) do
    {:reply, {:ok, Map.put(payload, :reply, "ok")}, socket}
  end

  defp reply_error(socket, payload) do
    {:reply, {:error, Map.put(payload, :reply, "error")}, socket}
  end

  defp fetch_membership(user, membership_id) do
    membership = Chat.get_membership!(user, membership_id)

    if membership.status in ["pending", "joined"],
      do: {:ok, membership},
      else: {:error, :invalid_buffer}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
  end

  defp fetch_direct_message_thread(user, thread_id) do
    {:ok, Chat.get_direct_message_thread!(user, thread_id)}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_direct_message}
  end

  defp connection_from_buffer(user, "channel:" <> membership_id) do
    with {:ok, membership} <- fetch_membership(user, membership_id) do
      {:ok, membership.server_connection}
    end
  end

  defp connection_from_buffer(user, "server:" <> connection_id) do
    {:ok, Chat.get_connection!(user, connection_id)}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_server}
  end

  defp connection_from_buffer(user, "direct:" <> thread_id) do
    with {:ok, thread} <- fetch_direct_message_thread(user, thread_id) do
      {:ok, thread.server_connection}
    end
  end

  defp connection_from_buffer(_user, _buffer_id), do: {:error, :invalid_buffer}

  defp membership_from_part_command(user, "channel:" <> membership_id, []) do
    fetch_membership(user, membership_id)
  end

  defp membership_from_part_command(user, buffer_id, [channel]) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id) do
      membership_for_channel(user, connection, channel)
    end
  end

  defp membership_from_part_command(_user, _buffer_id, _args), do: {:error, :invalid_command_args}

  defp membership_for_channel(user, connection, channel) do
    casemapping =
      case session_connection_info(connection) do
        {:ok, client_info} -> client_info.casemapping
        {:error, _reason} -> nil
      end

    membership = Chat.get_membership_by_channel!(user, connection, channel, casemapping)

    if membership.status in ["pending", "joined"],
      do: {:ok, membership},
      else: {:error, :invalid_buffer}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
  end

  defp put_reply_command_id({:reply, {status, payload}, socket}, command_id) do
    {:reply, {status, Map.put(payload, :command_id, command_id)}, socket}
  end

  defp channel_directory(connection, channels) do
    %{
      server_connection_id: connection.id,
      server_name: connection.name,
      server_host: connection.host,
      channels: channels
    }
  end

  defp list_channels(connection) do
    Session.list_channels(connection)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp session_connection_info(connection) do
    Session.connection_info(connection)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp execute_intent(connection, line, buffer_id, socket) do
    with {:ok, client_info} <- session_connection_info(connection),
         {:ok, result} <-
           resolve_and_execute_intent(connection, client_info, line, buffer_id, socket) do
      {:ok, result}
    end
  end

  defp resolve_and_execute_intent(connection, client_info, line, buffer_id, socket) do
    with {:ok, intent} <- CommandRegistry.resolve(line, client_info) do
      Session.execute(connection, intent, socket.assigns.command_id, buffer_id)
    end
  end

  defp say(membership, body) do
    Session.say(membership.server_connection, membership.channel, body)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp direct_message(thread, body) do
    if not is_nil(thread.closed_at) or String.starts_with?(thread.peer_key, "archived:") do
      {:error, :direct_message_closed}
    else
      Session.privmsg_thread(thread.server_connection, thread.id, body)
    end
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp part(membership, reason) do
    Session.part(membership.server_connection, membership.channel, reason)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp latest_message(user, membership) do
    user
    |> Chat.list_messages(membership.id, 1)
    |> List.first()
  end

  defp error_reason(:invalid_buffer), do: "invalid_buffer"
  defp error_reason(:invalid_server), do: "invalid_server"
  defp error_reason(:invalid_direct_message), do: "invalid_direct_message"
  defp error_reason(:direct_message_closed), do: "direct_message_closed"
  defp error_reason(:invalid_command_args), do: "invalid_command_args"
  defp error_reason(:invalid_connection), do: "invalid_connection"
  defp error_reason(:not_connected), do: "not_connected"
  defp error_reason(:list_in_progress), do: "list_in_progress"
  defp error_reason(:list_timeout), do: "list_timeout"
  defp error_reason(:joining_channel), do: "joining_channel"
  defp error_reason(:not_joined), do: "not_joined"
  defp error_reason(%{code: code}), do: code
  defp error_reason(_reason), do: "send_failed"

  defp send_error_body(:not_connected), do: "Message could not be sent: not connected."

  defp send_error_body(:joining_channel),
    do: "Message could not be sent: still joining the channel."

  defp send_error_body(:not_joined), do: "Message could not be sent: not joined to the channel."
  defp send_error_body(%{message: message}), do: message
  defp send_error_body(_reason), do: "Message could not be sent."
end
