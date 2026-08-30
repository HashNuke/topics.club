defmodule TopicsClub.Irc.Session.ConnectionEvents do
  @moduledoc false

  require Logger

  alias TopicsClub.Chat.{ConnectionLifecycle, ServerConnectionLock}
  alias TopicsClub.Irc.ConnectionLock

  alias TopicsClub.Irc.Session.{
    ClientOptions,
    CommandLifecycle,
    ConnectionIssue,
    EventRecorder,
    JoinLifecycle,
    Registration
  }

  @max_retries 5
  @retry_delay_ms 5_000

  def connect(state) do
    maybe_pause_before_connect_lock(state.connection.id)

    case ConnectionLock.run_serialized(state.connection, fn -> connect_active(state) end) do
      {:error, reason} when reason in [:connection_deleting, :connection_not_found] ->
        {:stop, :normal}

      {:error, reason} ->
        {:stop, reason}

      result ->
        result
    end
  end

  defp connect_active(state) do
    connection = state.connection

    with :ok <- ServerConnectionLock.ensure_active(connection.id) do
      if Map.get(state, :retry_attempt, 0) == 0 do
        EventRecorder.server_line(
          connection,
          "Connecting to #{connection.host}:#{connection.port}."
        )
      end

      update_status(connection, "connecting")

      case Ircxd.Client.start_link(ClientOptions.build(connection, self())) do
        {:ok, client} ->
          Process.unlink(client)
          client_monitor = Process.monitor(client)
          maybe_suspend_client_after_start(client, connection.id)

          {:ok,
           state
           |> Map.put(:client, client)
           |> Map.put(:client_monitor, client_monitor)}

        {:error, reason} ->
          Logger.warning(
            "IRC connection failed for #{connection.host}:#{connection.port}: #{inspect(reason)}"
          )

          EventRecorder.server_line(
            connection,
            "Connection to #{connection.host}:#{connection.port} failed: #{inspect(reason)}.",
            "error"
          )

          update_status(connection, "errored")
          {:stop, reason}
      end
    else
      {:error, reason} when reason in [:connection_deleting, :connection_not_found] ->
        {:stop, :normal}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def registered(state) do
    {:ok, updated} = update_status(state.connection, "connected")

    message =
      if Map.get(state, :retry_attempt, 0) > 0,
        do: "Reconnected to #{updated.host}.",
        else: "Connected to #{updated.host}."

    EventRecorder.server_line(updated, message)
    cancel_retry_timer(Map.get(state, :retry_timer))

    state
    |> Map.put(:connection, updated)
    |> Map.put(:registered?, true)
    |> Map.put(:connection_issue, nil)
    |> Map.put(:preserve_error_status?, false)
    |> Map.put(:retry_attempt, 0)
    |> Map.put(:retry_timer, nil)
    |> Registration.refresh_client_info()
    |> JoinLifecycle.schedule_flush()
  end

  def connect_error(state, reason) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")

    if Map.get(state, :retry_attempt, 0) == 0 do
      EventRecorder.server_line(
        state.connection,
        "Connection error for #{state.connection.host}: #{inspect(reason)}.",
        "error"
      )

      update_status(state.connection, "errored")
    end

    state
  end

  def disconnected(state) do
    if Map.get(state, :retry_attempt, 0) == 0 do
      EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
      update_status(state.connection, "disconnected")
    end

    state
    |> CommandLifecycle.fail_all("Connection closed before completion.")
    |> Map.put(:registered?, false)
  end

  def reconnecting(state, payload \\ %{}) do
    attempt = Map.get(payload, :attempt, Map.get(state, :retry_attempt, 0))

    :telemetry.execute(
      [:topics_club, :irc, :session, :reconnect],
      %{system_time: System.system_time(), attempt: attempt},
      %{connection_id: state.connection.id}
    )

    update_status(state.connection, "connecting")

    if attempt == 0 do
      EventRecorder.server_line(
        state.connection,
        "Reconnecting to #{state.connection.host}:#{state.connection.port}."
      )
    end

    %{
      state
      | registered?: false,
        isupport_received?: false,
        isupport_seen?: false,
        registration_boundary_reached?: false,
        join_validation_ready?: false,
        joins_flushed?: false,
        join_flush_timer: JoinLifecycle.cancel_flush(state),
        sent_joins: MapSet.new(),
        joined_channels: MapSet.new()
    }
  end

  def require_human(state, issue) when is_map(issue) do
    EventRecorder.server_line(
      state.connection,
      issue.summary,
      "error",
      %{connection_issue: issue}
    )

    {:ok, updated} = require_attention(state.connection)
    send(self(), :halt_for_connection_issue)

    %{
      state
      | connection: updated,
        connection_issue: issue,
        preserve_error_status?: true
    }
  end

  def client_exited(
        %{client: client, client_monitor: monitor_ref} = state,
        monitor_ref,
        client,
        reason
      )
      when is_pid(client) and is_reference(monitor_ref) do
    state = %{state | client: nil, client_monitor: nil}

    if Map.get(state, :connection_issue) do
      {:stop, :normal, %{state | preserve_error_status?: true}}
    else
      retry_or_stop(state, reason)
    end
  end

  def client_exited(state, _monitor_ref, _pid, _reason), do: {:noreply, state}

  def retry_connect(%{retry_attempt: attempt} = state, attempt) do
    state = %{state | retry_timer: nil}

    case connect(state) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> retry_or_stop(state, reason)
    end
  end

  def retry_connect(state, _stale_attempt), do: {:noreply, state}

  def terminate(state) do
    cancel_retry_timer(Map.get(state, :retry_timer))
    state = CommandLifecycle.fail_all(state, "IRC session stopped before completion.")

    unless Map.get(state, :preserve_error_status?, false) do
      update_status(state.connection, "disconnected")
    end

    state
  end

  defp update_status(connection, status) do
    connection =
      if status == "connected" do
        case ConnectionLifecycle.touch_connected(connection) do
          {:ok, updated} -> updated
          {:error, _changeset} -> connection
        end
      else
        connection
      end

    ConnectionLifecycle.broadcast_status(connection, status)
    {:ok, connection}
  rescue
    DBConnection.ConnectionError -> {:ok, connection}
    Ecto.NoResultsError -> {:ok, connection}
    Ecto.StaleEntryError -> {:ok, connection}
    DBConnection.OwnershipError -> {:ok, connection}
  catch
    :exit, _reason -> {:ok, connection}
  end

  defp require_attention(connection) do
    ConnectionLifecycle.require_attention(connection)
  rescue
    DBConnection.ConnectionError -> {:ok, connection}
    Ecto.NoResultsError -> {:ok, connection}
    Ecto.StaleEntryError -> {:ok, connection}
    DBConnection.OwnershipError -> {:ok, connection}
  catch
    :exit, _reason -> {:ok, connection}
  end

  defp retry_or_stop(state, reason) do
    retry_attempt = Map.get(state, :retry_attempt, 0)

    if retry_attempt < @max_retries do
      schedule_retry(state, retry_attempt + 1)
    else
      stop_for_exhausted_retries(state, reason)
    end
  end

  defp schedule_retry(state, attempt) do
    if attempt == 1 do
      EventRecorder.server_line(
        state.connection,
        "Connection lost. Trying up to #{@max_retries} times before asking for help.",
        "notice"
      )
    end

    timer = Process.send_after(self(), {:retry_connect, attempt}, retry_delay_ms())

    state =
      state
      |> Map.put(:client, nil)
      |> Map.put(:retry_attempt, attempt)
      |> Map.put(:retry_timer, timer)
      |> reconnecting(%{attempt: attempt})

    {:noreply, state}
  end

  defp stop_for_exhausted_retries(state, reason) do
    issue = ConnectionIssue.retries_exhausted(reason, state.connection)

    {:stop, :normal,
     state
     |> require_human(issue)
     |> Map.put(:client, nil)
     |> Map.put(:retry_timer, nil)}
  end

  defp cancel_retry_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_retry_timer(_timer), do: :ok

  defp retry_delay_ms do
    Application.get_env(:topics_club_engine, :session_retry_delay_ms, @retry_delay_ms)
  end

  defp maybe_pause_before_connect_lock(connection_id) do
    case Application.get_env(:topics_club_engine, :session_connect_before_lock_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(test_pid, {:session_connect_paused, self(), barrier_ref, connection_id})

        receive do
          {:continue_session_connect, ^barrier_ref} -> :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp maybe_suspend_client_after_start(client, connection_id) do
    case Application.get_env(:topics_club_engine, :session_client_after_start_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        true = :erlang.suspend_process(client)
        send(test_pid, {:irc_client_suspended, client, barrier_ref, connection_id})

      _not_paused ->
        :ok
    end
  end
end
