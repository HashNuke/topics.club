defmodule Ircpipe.Irc.Bouncer do
  use GenServer

  require Logger

  alias Ircpipe.Chat.ConnectionActivity
  alias Ircpipe.Irc.SessionSupervisor

  @idle_timeout :timer.hours(24)
  @sweep_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    enabled? =
      Keyword.get(
        opts,
        :enabled?,
        Application.get_env(:topics_club_engine, :irc_bouncer_enabled, true)
      )

    state = %{
      enabled?: enabled?,
      idle_timeout: Keyword.get(opts, :idle_timeout, @idle_timeout),
      sweep_interval: Keyword.get(opts, :sweep_interval, @sweep_interval)
    }

    if state.enabled? do
      send(self(), :start_recent_sessions)
      schedule_sweep(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:start_recent_sessions, state) do
    if state.enabled? do
      state
      |> cutoff()
      |> ConnectionActivity.recently_seen()
      |> Enum.each(&start_session/1)
    end

    {:noreply, state}
  end

  def handle_info(:sweep_inactive_sessions, state) do
    if state.enabled? do
      state
      |> cutoff()
      |> ConnectionActivity.inactive()
      |> Enum.each(&disconnect_session/1)

      schedule_sweep(state)
    end

    {:noreply, state}
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep_inactive_sessions, state.sweep_interval)
  end

  defp cutoff(state) do
    DateTime.utc_now(:second)
    |> DateTime.add(-div(state.idle_timeout, 1_000), :second)
  end

  defp start_session(connection) do
    case SessionSupervisor.start_session(connection) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not start IRC bouncer session #{connection.id}: #{inspect(reason)}")
        :ok
    end
  catch
    :exit, reason ->
      Logger.warning("Could not start IRC bouncer session #{connection.id}: #{inspect(reason)}")
      :ok
  end

  defp disconnect_session(connection) do
    SessionSupervisor.stop_session(connection, "idle timeout")
    :ok
  rescue
    DBConnection.ConnectionError -> :ok
    DBConnection.OwnershipError -> :ok
    Ecto.NoResultsError -> :ok
    Ecto.StaleEntryError -> :ok
  catch
    :exit, _reason -> :ok
  end
end
