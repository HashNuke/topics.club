defmodule TopicsClubWeb.UserChannel.CommandHandler do
  @moduledoc false

  alias TopicsClub.EngineClient
  alias TopicsClub.Irc.Commands
  alias TopicsClub.Irc.Identifier
  alias TopicsClub.Realtime.Event
  alias TopicsClubWeb.UserChannel.BufferResolver
  alias TopicsClubWeb.UserChannel.ChannelDirectory
  alias TopicsClubWeb.UserChannel.ErrorResponse
  alias TopicsClubWeb.UserChannel.Reply

  def suggest(input, socket) do
    Reply.ok(socket, %{commands: Commands.suggest(input)})
  end

  def parse(input, socket) do
    case Commands.parse(input) do
      {:ok, command} ->
        Reply.ok(socket, %{command: command})

      {:error, :not_a_command} ->
        Reply.error(socket, %{reason: "not_a_command"})

      {:error, {:unknown_command, command}} ->
        Reply.error(socket, %{reason: "unknown_command", command: command})
    end
  end

  def run(%{"input" => input} = payload, socket) do
    command_id = Map.get(payload, "command_id") || Ecto.UUID.generate()
    socket = Phoenix.Socket.assign(socket, :command_id, command_id)

    result =
      case Commands.parse(input) do
        {:ok, command} ->
          run_command(command, socket.assigns.current_user, Map.get(payload, "buffer_id"), socket)

        {:error, :not_a_command} ->
          Reply.error(socket, %{reason: "not_a_command"})

        {:error, {:unknown_command, command}} ->
          Reply.error(socket, %{reason: "unknown_command", command: command})
      end

    put_reply_command_id(result, command_id)
  end

  defp run_command(command, _user, nil, socket),
    do: Reply.error(socket, %{reason: "invalid_buffer", command: command})

  defp run_command(%{name: "join", args: [channel]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id) do
      case BufferResolver.channel_membership(user, connection, channel) do
        {:ok, membership} ->
          join_reply(socket, command, connection, membership, %{status: membership.status})

        {:error, :invalid_buffer} ->
          execute_join(command, connection, channel, buffer_id, socket)

        {:error, reason} ->
          Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
      end
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "list", args: []} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, directory} <- ChannelDirectory.fetch(user, connection) do
      Reply.ok(socket, %{command: command, directory: directory})
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: name, args: args} = command, user, buffer_id, socket)
       when name in ["part", "leave"] do
    with {:ok, membership} <- BufferResolver.part_membership(user, buffer_id, args),
         {:ok, result} <-
           execute_intent(
             membership.server_connection,
             "PART #{membership.channel} :leaving",
             "channel:#{membership.id}",
             socket
           ) do
      Reply.ok(
        socket,
        result
        |> Map.put(:command, command)
        |> Map.put(:buffer_id, "channel:#{membership.id}")
      )
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(
         %{name: "me", args: [body]} = command,
         user,
         "channel:" <> membership_id,
         socket
       ) do
    with {:ok, membership} <- BufferResolver.membership(user, membership_id),
         {:ok, result} <-
           execute_intent(
             membership.server_connection,
             "PRIVMSG #{membership.channel} :\x01ACTION #{body}\x01",
             "channel:#{membership.id}",
             socket
           ),
         [message] <- result.channel_messages do
      Reply.ok(socket, %{
        command: command,
        command_id: result.command_id,
        status: result.status,
        message: Event.message(message, "channel:#{membership.id}")
      })
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})

      [] ->
        Reply.error(socket, %{reason: "send_failed", command: command})
    end
  end

  defp run_command(
         %{name: "me", args: [body]} = command,
         user,
         "direct:" <> thread_id,
         socket
       ) do
    with {:ok, thread} <- BufferResolver.direct_message_thread(user, thread_id),
         connection = thread.server_connection,
         {:ok, result} <-
           execute_intent(
             connection,
             "PRIVMSG #{thread.peer_nick} :\x01ACTION #{body}\x01",
             "server:#{connection.id}",
             socket
           ),
         [%{thread: sent_thread, message: message}] <- result.direct_messages do
      event = Event.direct_message_thread(sent_thread, connection)

      Reply.ok(
        socket,
        Map.merge(event, %{
          command: command,
          command_id: result.command_id,
          status: result.status,
          message:
            Event.message(message, "direct:#{sent_thread.id}", %{peer_nick: sent_thread.peer_nick})
        })
      )
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})

      [] ->
        Reply.error(socket, %{reason: "send_failed", command: command})
    end
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "send_failed", command: command})
  end

  defp run_command(%{name: "msg", args: [target, body]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, %{connection_info: client_info}} <- session_connection_info(user, connection),
         true <- Identifier.valid_nick?(target, Map.get(client_info, :isupport, %{})),
         {:ok, result} <-
           execute_intent(
             connection,
             "PRIVMSG #{target} :#{body}",
             "server:#{connection.id}",
             socket
           ),
         [%{thread: thread, message: message}] <- result.direct_messages do
      event = Event.direct_message_thread(thread, connection)

      Reply.ok(
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
        Reply.error(socket, %{reason: "invalid_nick", command: command})

      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})

      [] ->
        Reply.error(socket, %{reason: "send_failed", command: command})
    end
  rescue
    Ecto.NoResultsError -> Reply.error(socket, %{reason: "send_failed", command: command})
  end

  defp run_command(%{name: "nick", args: [nick]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, result} <- execute_intent(connection, "NICK #{nick}", buffer_id, socket) do
      Reply.ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "whoami", args: []} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, %{connection_info: %{current_nick: nick}}} <-
           session_connection_info(user, connection),
         true <- is_binary(nick),
         {:ok, result} <- execute_intent(connection, "WHOIS #{nick}", buffer_id, socket) do
      Reply.ok(socket, Map.put(result, :command, command))
    else
      false ->
        Reply.error(socket, %{reason: "not_connected", command: command})

      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "whois", args: [nick]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, result} <- execute_intent(connection, "WHOIS #{nick}", buffer_id, socket) do
      Reply.ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "topic", args: [channel]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, membership} <- BufferResolver.channel_membership(user, connection, channel),
         {:ok, result} <-
           execute_intent(
             connection,
             "TOPIC #{membership.channel}",
             "channel:#{membership.id}",
             socket
           ) do
      Reply.ok(socket, Map.put(result, :command, command))
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "topic", args: [channel, topic]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, membership} <- BufferResolver.channel_membership(user, connection, channel),
         {:ok, result} <-
           execute_intent(
             connection,
             "TOPIC #{membership.channel} :#{topic}",
             "channel:#{membership.id}",
             socket
           ) do
      Reply.ok(
        socket,
        result
        |> Map.put(:command, command)
        |> Map.put(:buffer_id, "channel:#{membership.id}")
      )
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(%{name: "quote", args: [line]} = command, user, buffer_id, socket) do
    with {:ok, connection} <- BufferResolver.connection(user, buffer_id),
         {:ok, result} <- execute_intent(connection, line, buffer_id, socket) do
      reply =
        result
        |> Map.drop([:channel_messages, :direct_messages])
        |> Map.put(:command, command)

      Reply.ok(socket, reply)
    else
      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp run_command(command, _user, _buffer_id, socket) do
    Reply.error(socket, %{reason: "invalid_command_args", command: command})
  end

  defp execute_join(command, connection, channel, buffer_id, socket) do
    case execute_intent(connection, "JOIN #{channel}", buffer_id, socket) do
      {:ok, %{membership: membership} = result} ->
        join_reply(socket, command, connection, membership, result)

      {:ok, _result} ->
        Reply.error(socket, %{reason: "send_failed", command: command})

      {:error, %{code: _code} = error} ->
        command_error(socket, command, error)

      {:error, reason} ->
        Reply.error(socket, %{reason: ErrorResponse.reason(reason), command: command})
    end
  end

  defp join_reply(socket, command, connection, membership, result) do
    reply =
      connection
      |> Event.buffer_joined(membership)
      |> Map.merge(Map.take(result, [:command_id, :display, :status]))
      |> Map.put(:command, command)
      |> Map.put(:buffer_id, "channel:#{membership.id}")

    Reply.ok(socket, reply)
  end

  defp put_reply_command_id({:reply, {status, payload}, socket}, command_id) do
    {:reply, {status, Map.put(payload, :command_id, command_id)}, socket}
  end

  defp command_error(socket, command, error) do
    Reply.error(socket, %{
      reason: ErrorResponse.reason(error),
      error: ErrorResponse.public_error(error),
      command: command
    })
  end

  defp session_connection_info(user, connection),
    do: EngineClient.connection_info(user.id, connection.id)

  defp execute_intent(connection, line, buffer_id, socket) do
    user = socket.assigns.current_user

    with {:ok, %{result: result}} <-
           EngineClient.execute_command(
             user.id,
             connection.id,
             line,
             socket.assigns.command_id,
             buffer_id
           ) do
      {:ok, result}
    end
  end
end
