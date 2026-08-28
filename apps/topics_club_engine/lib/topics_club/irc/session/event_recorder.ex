defmodule TopicsClub.Irc.Session.EventRecorder do
  @moduledoc false

  require Logger

  alias TopicsClub.Chat.{MessageIngestion, SystemMessages}
  alias TopicsClub.Irc.Session.Targets

  @recoverable_errors [
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Ecto.ConstraintError,
    Ecto.NoResultsError,
    Ecto.StaleEntryError
  ]

  def server_line(connection, body, kind \\ "system", metadata \\ %{}) do
    recover(:server_line, connection, fn ->
      MessageIngestion.record_server(connection, body, kind, nil, metadata)
    end)
  end

  def channel_line(state, channel, kind, nick, body) do
    recover(:channel_line, state.connection, fn ->
      SystemMessages.record(
        state.connection,
        channel,
        kind,
        nick,
        body,
        %{},
        Targets.casemapping(state)
      )
    end)
  end

  def present_nick_line(state, kind, nick, body_fun) do
    recover(:present_nick_line, state.connection, fn ->
      SystemMessages.record_for_present_nick(
        state.connection,
        kind,
        nick,
        body_fun,
        Targets.casemapping(state)
      )
    end)
  end

  def present_nick_line(state, kind, present_nick, message_nick, body_fun) do
    recover(:present_nick_line, state.connection, fn ->
      SystemMessages.record_for_present_nick(
        state.connection,
        kind,
        present_nick,
        message_nick,
        body_fun,
        Targets.casemapping(state)
      )
    end)
  end

  def irc_error(state, %{target: target} = payload) when is_binary(target) do
    if channel = Targets.channel(state, target) do
      SystemMessages.record(
        state.connection,
        channel,
        "error",
        nil,
        irc_error_body(payload),
        %{},
        Targets.casemapping(state)
      )
    else
      server_line(state.connection, irc_error_body(payload), "error")
    end
  rescue
    exception in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.ConstraintError,
      Ecto.StaleEntryError
    ] ->
      report_ingestion_failure(:irc_error, state.connection, exception.__struct__)
      {:ok, nil}

    Ecto.NoResultsError ->
      report_ingestion_failure(:irc_error, state.connection, Ecto.NoResultsError)
      server_line(state.connection, irc_error_body(payload), "error")
  catch
    :exit, _reason ->
      report_ingestion_failure(:irc_error, state.connection, :exit)
      {:ok, nil}
  end

  def irc_error(state, payload) do
    server_line(state.connection, irc_error_body(payload), "error")
  end

  defp irc_error_body(%{reason: reason}) when is_binary(reason), do: reason
  defp irc_error_body(%{code: code}), do: "IRC error #{code}."
  defp irc_error_body(_payload), do: "IRC error."

  defp recover(operation, connection, callback) do
    callback.()
  rescue
    exception in @recoverable_errors ->
      report_ingestion_failure(operation, connection, exception.__struct__)
      {:ok, nil}
  catch
    :exit, _reason ->
      report_ingestion_failure(operation, connection, :exit)
      {:ok, nil}
  end

  defp report_ingestion_failure(operation, connection, reason) do
    metadata = %{
      connection_id: Map.get(connection, :id),
      operation: operation,
      reason: reason
    }

    Logger.warning(
      "IRC event persistence failed " <>
        "connection_id=#{inspect(metadata.connection_id)} " <>
        "operation=#{inspect(operation)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:topics_club, :irc, :ingestion, :failure],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
