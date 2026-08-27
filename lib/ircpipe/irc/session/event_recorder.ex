defmodule Ircpipe.Irc.Session.EventRecorder do
  @moduledoc false

  alias Ircpipe.Chat.{MessageIngestion, SystemMessages}
  alias Ircpipe.Irc.Session.Targets

  def server_line(connection, body, kind \\ "system", metadata \\ %{}) do
    MessageIngestion.record_server(connection, body, kind, nil, metadata)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  def channel_line(state, channel, kind, nick, body) do
    SystemMessages.record(
      state.connection,
      channel,
      kind,
      nick,
      body,
      %{},
      Targets.casemapping(state)
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  def present_nick_line(state, kind, nick, body_fun) do
    SystemMessages.record_for_present_nick(
      state.connection,
      kind,
      nick,
      body_fun,
      Targets.casemapping(state)
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  def present_nick_line(state, kind, present_nick, message_nick, body_fun) do
    SystemMessages.record_for_present_nick(
      state.connection,
      kind,
      present_nick,
      message_nick,
      body_fun,
      Targets.casemapping(state)
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
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
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> server_line(state.connection, irc_error_body(payload), "error")
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  def irc_error(state, payload) do
    server_line(state.connection, irc_error_body(payload), "error")
  end

  defp irc_error_body(%{reason: reason}) when is_binary(reason), do: reason
  defp irc_error_body(%{code: code}), do: "IRC error #{code}."
  defp irc_error_body(_payload), do: "IRC error."
end
