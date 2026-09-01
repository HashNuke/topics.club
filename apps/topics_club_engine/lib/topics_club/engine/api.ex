defmodule TopicsClub.Engine.API do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.ChannelMembership
  alias TopicsClub.Chat.ConnectionLifecycle
  alias TopicsClub.Chat.ConnectionDeletion
  alias TopicsClub.Chat.DirectMessageThread
  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Chat.SystemMessages
  alias TopicsClub.Engine.Diagnostics
  alias TopicsClub.Engine.OperationLock
  alias TopicsClub.Engine.Serialization
  alias TopicsClub.EngineClient.Contract
  alias TopicsClub.EngineClient.Reply
  alias TopicsClub.Irc.CommandRegistry
  alias TopicsClub.Irc.ChannelListCache
  alias TopicsClub.Irc.ChannelListPage
  alias TopicsClub.Irc.ConnectionLock
  alias TopicsClub.Irc.Session
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.Repo

  def dispatch(request) do
    operation = if(is_map(request), do: Map.get(request, :operation))

    Logger.debug(
      "Engine API request operation=#{inspect(operation)}",
      request_id: request_id(request)
    )

    case Contract.validate(request) do
      :ok -> dispatch_valid(request)
      {:error, error} -> Reply.error(request, error)
    end
  rescue
    exception ->
      Logger.error(
        "engine API request failed request_id=#{request_id(request)}: #{Exception.message(exception)}"
      )

      Reply.error(request, :internal_error)
  catch
    kind, reason ->
      Logger.error(
        "engine API request failed request_id=#{request_id(request)}: #{inspect({kind, reason})}"
      )

      Reply.error(request, :internal_error)
  end

  defp dispatch_valid(%{operation: :protocol_info} = request) do
    Reply.ok(request, Diagnostics.snapshot())
  end

  defp dispatch_valid(%{operation: :connection_statuses} = request) do
    with {:ok, connections} <- load_connections(request.user_id, request.payload.connection_ids) do
      statuses =
        Enum.map(request.payload.connection_ids, fn connection_id ->
          connection = Map.fetch!(connections, connection_id)
          %{connection_id: connection.id, status: SessionLocator.status(connection)}
        end)

      Reply.ok(request, %{statuses: statuses})
    else
      {:error, reason} -> error_reply(request, reason)
    end
  end

  defp dispatch_valid(%{operation: operation} = request) do
    OperationLock.run(request.user_id, request.connection_id, fn ->
      dispatch_connection_operation(operation, request)
    end)
  end

  defp dispatch_connection_operation(operation, request) do
    with {:ok, user, connection} <- load_user_connection(request.user_id, request.connection_id),
         :ok <- ensure_available(connection, operation),
         :ok <- maybe_pause_after_connection_load(connection, operation),
         result <- execute(operation, request, user, connection) do
      result_reply(request, result)
    else
      {:error, reason} -> error_reply(request, reason)
    end
  end

  defp execute(:connection_info, _request, _user, connection) do
    safe_session_call(fn ->
      with {:ok, info} <- Session.connection_info(connection) do
        {:ok, %{connection_info: Serialization.connection_info(info)}}
      end
    end)
  end

  defp execute(:ensure_connection, request, _user, connection) do
    intent = Map.get(request.payload, :intent, "active")

    with {:ok, connection} <- prepare_connection_intent(connection, intent),
         {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      {:ok,
       %{
         connection: Serialization.connection(connection),
         status: SessionLocator.status(connection)
       }}
    end
  end

  defp execute(:reconnect_connection, request, _user, connection) do
    reason = Map.get(request.payload, :reason, "reconnecting")

    with {:ok, connection} <- prepare_connection_intent(connection, "active"),
         :ok <- safe_session_call(fn -> SessionSupervisor.stop_session(connection, reason) end),
         {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      {:ok,
       %{
         connection: Serialization.connection(connection),
         status: SessionLocator.status(connection)
       }}
    end
  end

  defp execute(:disconnect_connection, request, _user, connection) do
    reason = Map.get(request.payload, :reason, "leaving")
    session_running? = is_pid(SessionLocator.whereis(connection))

    with {:ok, connection} <- update_desired_state(connection, "paused"),
         :ok <- safe_session_call(fn -> SessionSupervisor.stop_session(connection, reason) end),
         {:ok, connection} <- maybe_mark_disconnected(connection, session_running?) do
      {:ok,
       %{
         connection: Serialization.connection(connection),
         status: "disconnected"
       }}
    end
  end

  defp execute(:delete_connection, _request, user, connection) do
    with {:ok, _deleted} <- ConnectionDeletion.delete(user, connection.id) do
      {:ok, %{connection_id: connection.id, deleted: true}}
    end
  end

  defp execute(:join_channel, request, user, connection) do
    with {:ok, connection} <- prepare_connection_intent(connection, "active"),
         {:ok, _pid} <- SessionSupervisor.start_session(connection),
         {:ok, membership, status} <-
           safe_session_call(fn ->
             Session.request_join(connection, user, request.payload.channel)
           end) do
      {:ok,
       %{
         membership: Serialization.membership(membership),
         status: Atom.to_string(status),
         connection_status: SessionLocator.status(connection)
       }}
    end
  end

  defp execute(:part_channel, request, _user, connection) do
    with {:ok, membership} <-
           load_membership(request.user_id, connection.id, request.payload.membership_id),
         :ok <-
           safe_session_call(fn ->
             Session.part(connection, membership.channel, Map.get(request.payload, :reason, ""))
           end) do
      {:ok, %{membership_id: membership.id, status: "sent"}}
    end
  end

  defp execute(:send_channel_message, request, _user, connection) do
    with {:ok, membership} <-
           load_membership(request.user_id, connection.id, request.payload.membership_id) do
      case safe_session_call(fn ->
             send_channel_message(
               connection,
               membership.channel,
               request.payload.body,
               request.payload.kind
             )
           end) do
        {:ok, message} ->
          {:ok, %{message: Serialization.message(message)}}

        {:error, reason} = error ->
          _result = record_send_failure(connection, membership, reason)
          error
      end
    end
  end

  defp execute(:send_direct_message, request, _user, connection) do
    with {:ok, thread} <-
           load_thread(request.user_id, connection.id, request.payload.thread_id),
         {:ok, %{thread: sent_thread, message: message}} <-
           safe_session_call(fn ->
             Session.privmsg_thread(connection, thread.id, request.payload.body)
           end) do
      {:ok,
       %{
         thread: Serialization.direct_message_thread(sent_thread),
         message: Serialization.message(message)
       }}
    end
  end

  defp execute(:execute_command, request, _user, connection) do
    with :ok <- authorize_buffer(request.user_id, connection.id, request.payload.buffer_id),
         {:ok, info} <- safe_session_call(fn -> Session.connection_info(connection) end),
         {:ok, intent} <- CommandRegistry.resolve(request.payload.line, info),
         {:ok, result} <-
           safe_session_call(fn ->
             Session.execute(
               connection,
               intent,
               request.payload.command_id,
               request.payload.buffer_id
             )
           end) do
      {:ok, %{result: Serialization.command_result(result)}}
    end
  end

  defp execute(:list_channels, request, _user, connection) do
    with {:ok, channels} <-
           ChannelListCache.fetch(connection, fn ->
             safe_session_call(fn -> Session.list_channels(connection) end)
           end) do
      {:ok,
       ChannelListPage.build(
         channels,
         Map.get(request.payload, :query, ""),
         Map.get(request.payload, :page, 1)
       )}
    end
  end

  defp result_reply(request, {:ok, data}), do: Reply.ok(request, data)
  defp result_reply(request, {:error, reason}), do: error_reply(request, reason)
  defp result_reply(request, :ok), do: Reply.ok(request, %{})
  defp result_reply(request, _result), do: Reply.error(request, :internal_error)

  defp error_reply(request, :unauthorized), do: Reply.error(request, :unauthorized)
  defp error_reply(request, :timeout), do: Reply.error(request, :timeout)
  defp error_reply(request, :list_timeout), do: Reply.error(request, :timeout)

  defp error_reply(request, reason)
       when reason in [:connection_not_found, :not_connected],
       do: Reply.error(request, :not_connected)

  defp error_reply(request, reason)
       when is_atom(reason) or is_map(reason),
       do: Reply.error(request, :invalid_state, Serialization.error_details(reason))

  defp error_reply(request, _reason), do: Reply.error(request, :internal_error)

  defp load_connections(user_id, connection_ids) do
    case Repo.get(User, user_id) do
      %User{} ->
        unique_ids = Enum.uniq(connection_ids)

        connections =
          ServerConnection
          |> where([connection], connection.user_id == ^user_id and connection.id in ^unique_ids)
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        if map_size(connections) == length(unique_ids) do
          {:ok, connections}
        else
          {:error, :unauthorized}
        end

      nil ->
        {:error, :unauthorized}
    end
  end

  defp load_user_connection(user_id, connection_id) do
    with %User{} = user <- Repo.get(User, user_id),
         %ServerConnection{} = connection <-
           Repo.get_by(ServerConnection, id: connection_id, user_id: user_id) do
      {:ok, user, connection}
    else
      _missing -> {:error, :unauthorized}
    end
  end

  defp load_membership(user_id, connection_id, membership_id) do
    case Repo.get_by(ChannelMembership,
           id: membership_id,
           user_id: user_id,
           server_connection_id: connection_id
         ) do
      %ChannelMembership{} = membership -> {:ok, membership}
      nil -> {:error, :unauthorized}
    end
  end

  defp load_thread(user_id, connection_id, thread_id) do
    case Repo.get_by(DirectMessageThread,
           id: thread_id,
           user_id: user_id,
           server_connection_id: connection_id
         ) do
      %DirectMessageThread{} = thread -> {:ok, thread}
      nil -> {:error, :unauthorized}
    end
  end

  defp ensure_available(%ServerConnection{deleting: true}, :delete_connection),
    do: :ok

  defp ensure_available(%ServerConnection{deleting: true}, _operation),
    do: {:error, :connection_deleting}

  defp ensure_available(%ServerConnection{}, _operation), do: :ok

  defp prepare_connection_intent(%ServerConnection{desired_state: "paused"}, "restore") do
    {:error, :connection_paused}
  end

  defp prepare_connection_intent(%ServerConnection{} = connection, "restore"),
    do: {:ok, connection}

  defp prepare_connection_intent(%ServerConnection{} = connection, "active"),
    do: update_desired_state(connection, "connected")

  defp update_desired_state(connection, desired_state) do
    ConnectionLock.run(connection, fn ->
      case Repo.get_by(ServerConnection, id: connection.id, user_id: connection.user_id) do
        %ServerConnection{deleting: false} = active_connection ->
          changes =
            if desired_state == "connected" and active_connection.status == "errored" do
              %{desired_state: desired_state, status: "connecting"}
            else
              %{desired_state: desired_state}
            end

          active_connection
          |> Ecto.Changeset.change(changes)
          |> Repo.update()

        %ServerConnection{deleting: true} ->
          {:error, :connection_deleting}

        nil ->
          {:error, :unauthorized}
      end
    end)
  end

  defp maybe_mark_disconnected(connection, true), do: {:ok, connection}

  defp maybe_mark_disconnected(connection, false) do
    ConnectionLifecycle.update_status(connection, "disconnected")
  end

  defp send_channel_message(connection, channel, body, "message"),
    do: Session.say(connection, channel, body)

  defp send_channel_message(connection, channel, body, "action"),
    do: Session.action(connection, channel, body)

  defp record_send_failure(connection, membership, reason) do
    SystemMessages.record(
      connection,
      membership.channel,
      "error",
      nil,
      send_failure_body(reason)
    )
  end

  defp send_failure_body(:not_connected),
    do: "Message could not be sent: not connected."

  defp send_failure_body(:joining_channel),
    do: "Message could not be sent: still joining the channel."

  defp send_failure_body(:not_joined),
    do: "Message could not be sent: not joined to the channel."

  defp send_failure_body(%{message: message}) when is_binary(message), do: message
  defp send_failure_body(_reason), do: "Message could not be sent."

  defp authorize_buffer(_user_id, connection_id, "server:" <> id) do
    if cast_id(id) == {:ok, connection_id}, do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_buffer(user_id, connection_id, "channel:" <> id) do
    with {:ok, membership_id} <- cast_id(id),
         {:ok, _membership} <- load_membership(user_id, connection_id, membership_id) do
      :ok
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  defp authorize_buffer(user_id, connection_id, "direct:" <> id) do
    with {:ok, thread_id} <- cast_id(id),
         {:ok, _thread} <- load_thread(user_id, connection_id, thread_id) do
      :ok
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  defp authorize_buffer(_user_id, _connection_id, _buffer_id), do: {:error, :unauthorized}

  defp cast_id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      _invalid -> {:error, :invalid_id}
    end
  end

  defp safe_session_call(callback) do
    callback.()
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :not_connected}
    :exit, :noproc -> {:error, :not_connected}
    :exit, _reason -> {:error, :not_connected}
  end

  defp maybe_pause_after_connection_load(connection, operation) do
    case Application.get_env(:topics_club_engine, :engine_api_after_connection_load_barrier) do
      {test_pid, barrier_ref, ^operation} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)

        send(
          test_pid,
          {:engine_api_connection_loaded, self(), barrier_ref, operation, connection.id}
        )

        receive do
          {:continue_engine_api_connection, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id(_request), do: "invalid"
end
