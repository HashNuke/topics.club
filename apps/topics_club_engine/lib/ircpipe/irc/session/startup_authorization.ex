defmodule Ircpipe.Irc.Session.StartupAuthorization do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircpipe.Repo

  def load(%ServerConnection{} = requested_connection) do
    ConnectionLock.run(requested_connection, fn ->
      case authoritative_connection(requested_connection) do
        %ServerConnection{desired_state: "connected"} = connection ->
          pending_channels = JoinLifecycle.persisted_channels(connection)
          maybe_pause_after_lookup(connection)
          {connection, pending_channels}

        %ServerConnection{desired_state: "paused"} ->
          {:error, :connection_paused}

        nil ->
          nil
      end
    end)
  end

  defp authoritative_connection(%ServerConnection{id: id, user_id: user_id}) do
    ServerConnection
    |> where(
      [connection],
      connection.id == ^id and connection.user_id == ^user_id and not connection.deleting
    )
    |> Repo.one()
  end

  defp maybe_pause_after_lookup(connection) do
    case Application.get_env(:topics_club_engine, :session_start_after_lookup_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:session_start_paused, self(), barrier_ref, connection.id})

        receive do
          {:continue_session_start, ^barrier_ref} ->
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
