defmodule Ircpipe.Irc.SessionSupervisor do
  use DynamicSupervisor

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.Session.ClientLifecycle
  alias Ircpipe.Irc.SessionLocator

  @stop_attempts 3
  @stop_timeout 5_000
  @name_release_attempts 100
  @name_release_interval 1

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000, max_seconds: 10)
  end

  def start_session(%ServerConnection{} = connection) do
    spec = {Session, connection}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> {:error, :connection_not_found}
      other -> other
    end
  end

  def stop_session(%ServerConnection{} = connection, reason \\ "leaving") do
    do_stop_session(connection, reason, @stop_attempts)
  end

  def stop_for_deletion(%ServerConnection{} = connection) do
    registry_key = {connection.user_id, connection.id}
    client = registered_client(registry_key)

    case Registry.lookup(Ircpipe.Irc.SessionRegistry, registry_key) do
      [{pid, _value}] when is_pid(pid) ->
        session_ref = Process.monitor(pid)

        case monitor_status(session_ref, pid) do
          :down ->
            ClientLifecycle.stop(client)

          :up ->
            maybe_pause_stop_after_lookup(pid)
            Process.exit(pid, :shutdown)

            with :ok <- ClientLifecycle.stop(client),
                 :ok <- await_deletion_process_down(session_ref, pid, :session_stop_timeout) do
              :ok
            end
        end

      [] ->
        ClientLifecycle.stop(client)
    end
  end

  defp do_stop_session(_connection, _reason, 0), do: {:error, :session_stop_race}

  defp do_stop_session(connection, reason, attempts_left) do
    case SessionLocator.whereis(connection) do
      pid when is_pid(pid) ->
        maybe_pause_stop_after_lookup(pid)
        monitor_ref = Process.monitor(pid)

        case quit_session(pid, reason) do
          :ok ->
            await_session_down(
              monitor_ref,
              pid,
              connection,
              reason,
              attempts_left
            )

          {:error, :closed} ->
            case stop_closed_session(pid) do
              :ok ->
                await_session_down(
                  monitor_ref,
                  pid,
                  connection,
                  reason,
                  attempts_left
                )

              error ->
                forget_monitor(monitor_ref, error)
            end

          {:exit, {:noproc, _call}} ->
            forget_monitor(monitor_ref)
            retry_stop(connection, reason, pid, attempts_left)

          {:exit, :noproc} ->
            forget_monitor(monitor_ref)
            retry_stop(connection, reason, pid, attempts_left)

          {:exit, {:normal, _call}} ->
            forget_monitor(monitor_ref)
            retry_stop(connection, reason, pid, attempts_left)

          {:exit, :normal} ->
            forget_monitor(monitor_ref)
            retry_stop(connection, reason, pid, attempts_left)

          {:exit, exit_reason} ->
            forget_monitor(monitor_ref, {:error, {:session_exit, exit_reason}})

          error ->
            forget_monitor(monitor_ref, error)
        end

      nil ->
        :ok
    end
  end

  defp quit_session(pid, reason) do
    GenServer.call(pid, {:quit, reason})
  catch
    :exit, exit_reason -> {:exit, exit_reason}
  end

  defp retry_stop(connection, reason, pid, attempts_left) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok ->
        await_name_release(
          connection,
          reason,
          pid,
          attempts_left,
          @name_release_attempts
        )

      {:error, :not_found} ->
        await_name_release(
          connection,
          reason,
          pid,
          attempts_left,
          @name_release_attempts
        )

      {:error, terminate_reason} ->
        {:error, {:session_terminate, terminate_reason}}
    end
  catch
    :exit, exit_reason -> {:error, {:session_supervisor_exit, exit_reason}}
  end

  defp stop_closed_session(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, :noproc -> :ok
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  defp await_session_down(monitor_ref, pid, connection, reason, attempts_left) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        await_name_release(
          connection,
          reason,
          pid,
          attempts_left,
          @name_release_attempts
        )
    after
      @stop_timeout -> forget_monitor(monitor_ref, {:error, :session_stop_timeout})
    end
  end

  defp await_deletion_process_down(monitor_ref, pid, timeout_error) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      @stop_timeout -> forget_monitor(monitor_ref, {:error, timeout_error})
    end
  end

  defp monitor_status(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :down
    after
      0 -> :up
    end
  end

  defp registered_client(registry_key) do
    case Registry.lookup(Ircpipe.Irc.ClientRegistry, registry_key) do
      [{client, _value}] when is_pid(client) -> client
      [] -> nil
    end
  end

  defp await_name_release(_connection, _reason, _pid, _attempts_left, 0) do
    {:error, :session_name_release_timeout}
  end

  defp await_name_release(connection, reason, pid, attempts_left, release_attempts_left) do
    registry_key = {connection.user_id, connection.id}

    case Registry.lookup(Ircpipe.Irc.SessionRegistry, registry_key) do
      [] ->
        :ok

      [{^pid, _value}] ->
        receive do
        after
          @name_release_interval ->
            await_name_release(
              connection,
              reason,
              pid,
              attempts_left,
              release_attempts_left - 1
            )
        end

      [{_replacement_pid, _value}] ->
        do_stop_session(connection, reason, attempts_left - 1)
    end
  end

  defp forget_monitor(monitor_ref, result \\ :ok) do
    Process.demonitor(monitor_ref, [:flush])
    result
  end

  defp maybe_pause_stop_after_lookup(pid) do
    case Application.get_env(:topics_club_engine, :pause_session_stop_after_lookup) do
      test_pid when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:session_stop_paused, self(), pid})

        receive do
          {:continue_session_stop, ^pid} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end
end
