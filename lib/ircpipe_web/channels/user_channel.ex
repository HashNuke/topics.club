defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Commands
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Realtime.Event

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if Integer.to_string(socket.assigns.current_user.id) == user_id do
      Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user_id}")

      {:ok,
       %{
         server_time: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
         missed_event_cursor: nil
       }, socket}
    else
      {:error, %{reason: "unauthorized"}}
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

  def handle_info({:buffer_left, payload}, socket) do
    push(socket, "buffer:left", payload)
    {:noreply, socket}
  end

  def handle_info({:buffer_joined, payload}, socket) do
    push(socket, "buffer:joined", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("command:suggest", %{"input" => input}, socket) do
    {:reply, {:ok, %{commands: Commands.suggest(input)}}, socket}
  end

  def handle_in("command:parse", %{"input" => input}, socket) do
    reply_with_command(input, socket)
  end

  def handle_in("command:run", %{"input" => input} = payload, socket) do
    case Commands.parse(input) do
      {:ok, command} ->
        run_command(command, socket.assigns.current_user, Map.get(payload, "buffer_id"), socket)

      {:error, :not_a_command} ->
        {:reply, {:error, %{reason: "not_a_command"}}, socket}

      {:error, {:unknown_command, command}} ->
        {:reply, {:error, %{reason: "unknown_command", command: command}}, socket}
    end
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
          message: Event.message(message, "channel:#{membership.id}")
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
          version: 1,
          event_id: "buffer_left:channel:#{membership.id}",
          occurred_at: DateTime.utc_now(:second),
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
        version: 1,
        event_id: "server_status:#{connection.id}",
        occurred_at: DateTime.utc_now(:second),
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
          version: 1,
          event_id: "server_status:#{connection.id}",
          occurred_at: DateTime.utc_now(:second),
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

  defp run_command(command, _user, nil, socket) do
    {:reply, {:ok, %{command: command}}, socket}
  end

  defp run_command(%{name: "join", args: [channel]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, membership} <- Chat.join_channel(user, connection, channel),
         :ok <- Session.join(connection, channel) do
      Chat.record_server_message(connection, "Joining #{membership.channel}.", "command")
      {:reply, {:ok, %{command: command, buffer_id: "channel:#{membership.id}"}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(%{name: name, args: args} = command, user, buffer_id, socket)
       when name in ["part", "leave"] do
    with {:ok, membership} <- membership_from_part_command(user, buffer_id, args),
         :ok <- part(membership, "leaving"),
         :ok <- Chat.leave_channel(user, membership) do
      Chat.record_server_message(
        membership.server_connection,
        "Leaving #{membership.channel}.",
        "command"
      )

      {:reply, {:ok, %{command: command, buffer_id: "channel:#{membership.id}"}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(
         %{name: "me", args: [body]} = command,
         user,
         "channel:" <> membership_id,
         socket
       ) do
    with {:ok, membership} <- fetch_membership(user, membership_id),
         :ok <- Session.action(membership.server_connection, membership.channel, body),
         message <- latest_message(user, membership) do
      {:reply,
       {:ok,
        %{
          command: command,
          message: Event.message(message, "channel:#{membership.id}")
        }}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(%{name: "msg", args: [target, body]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         :ok <- Session.privmsg(connection, target, body) do
      Chat.record_server_message(connection, "Sent message to #{target}.", "command")
      {:reply, {:ok, %{command: command}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(%{name: "nick", args: [nick]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         :ok <- Session.nick(connection, nick) do
      Chat.record_server_message(connection, "Requested nickname change to #{nick}.", "command")
      {:reply, {:ok, %{command: command}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(%{name: "topic", args: [channel, topic]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, membership} <- membership_for_channel(user, connection, channel),
         :ok <- Session.topic(connection, membership.channel, topic) do
      Chat.record_channel_system_message(
        connection,
        membership.channel,
        "command",
        connection.nickname,
        "Requested topic change: #{topic}"
      )

      {:reply, {:ok, %{command: command, buffer_id: "channel:#{membership.id}"}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(%{name: "quote", args: [line]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- connection_from_buffer(user, buffer_id),
         {:ok, raw_command, params} <- parse_raw_command(line),
         :ok <- Session.raw(connection, raw_command, params) do
      Chat.record_server_message(connection, "Sent raw IRC command: #{line}.", "command")
      {:reply, {:ok, %{command: command}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: error_reason(reason), command: command}}, socket}
    end
  end

  defp run_command(command, _user, _buffer_id, socket) do
    {:reply, {:error, %{reason: "invalid_command_args", command: command}}, socket}
  end

  defp fetch_membership(user, membership_id) do
    {:ok, Chat.get_membership!(user, membership_id)}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
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
    {:ok, Chat.get_membership_by_channel!(user, connection, channel)}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
  end

  defp parse_raw_command(line) do
    case String.split(String.trim(line), ~r/\s+/, trim: true) do
      [] -> {:error, :invalid_command_args}
      [command | params] -> {:ok, String.upcase(command), params}
    end
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

  defp error_reason(:invalid_buffer), do: "invalid_buffer"
  defp error_reason(:invalid_server), do: "invalid_server"
  defp error_reason(:invalid_command_args), do: "invalid_command_args"
  defp error_reason(:invalid_connection), do: "invalid_connection"
  defp error_reason(:not_connected), do: "not_connected"
  defp error_reason(_reason), do: "send_failed"
end
