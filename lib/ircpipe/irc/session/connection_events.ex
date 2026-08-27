defmodule Ircpipe.Irc.Session.ConnectionEvents do
  @moduledoc false

  require Logger

  alias Ircpipe.Chat.ConnectionLifecycle

  alias Ircpipe.Irc.Session.{
    ClientOptions,
    CommandLifecycle,
    EventRecorder,
    JoinLifecycle,
    Registration
  }

  def connect(state) do
    connection = state.connection
    EventRecorder.server_line(connection, "Connecting to #{connection.host}:#{connection.port}.")
    update_status(connection, "connecting")

    case Ircxd.Client.start_link(ClientOptions.build(connection, self())) do
      {:ok, client} ->
        {:ok, %{state | client: client}}

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
  end

  def registered(state) do
    {:ok, updated} = update_status(state.connection, "connected")
    EventRecorder.server_line(updated, "Connected to #{updated.host}.")

    state
    |> Map.put(:connection, updated)
    |> Map.put(:registered?, true)
    |> Registration.refresh_client_info()
    |> JoinLifecycle.schedule_flush()
  end

  def connect_error(state, reason) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")

    EventRecorder.server_line(
      state.connection,
      "Connection error for #{state.connection.host}: #{inspect(reason)}.",
      "error"
    )

    update_status(state.connection, "errored")
    state
  end

  def disconnected(state) do
    EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
    update_status(state.connection, "disconnected")
    CommandLifecycle.fail_all(state, "Connection closed before completion.")
  end

  def reconnecting(state) do
    EventRecorder.server_line(
      state.connection,
      "Reconnecting to #{state.connection.host}:#{state.connection.port}."
    )

    update_status(state.connection, "connecting")

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

  def terminate(state) do
    state = CommandLifecycle.fail_all(state, "IRC session stopped before completion.")
    update_status(state.connection, "disconnected")
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
end
