defmodule Ircpipe.Irc.Session.DepartureCommands do
  @moduledoc false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.ServerConnectionLock
  alias Ircpipe.Irc.{ConnectionLock, Session.EventRecorder, Session.Targets}

  def part(state, channel, reason) do
    serialize(state, fn -> part_active(state, channel, reason) end)
  end

  defp part_active(state, channel, reason) do
    case ServerConnectionLock.ensure_active(state.connection.id) do
      :ok -> do_part(state, channel, reason)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp do_part(state, channel, reason) do
    key = Targets.key(state, channel)

    if queued_locally?(state, key) do
      cancel_queued_part(state, channel, key)
    else
      transmit_part(state, channel, reason, key)
    end
  end

  def quit(state, reason) do
    serialize(state, fn -> quit_active(state, reason) end)
  end

  defp quit_active(state, reason) do
    with :ok <- ServerConnectionLock.ensure_active(state.connection.id) do
      do_quit(state, reason)
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp do_quit(state, reason) do
    result = maybe_quit(state.client, reason)
    EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
    {normalize_result(result), state}
  end

  defp serialize(state, callback) do
    case ConnectionLock.run_serialized(state.connection, callback) do
      {:error, reason} -> {{:error, reason}, state}
      result -> result
    end
  end

  defp queued_locally?(state, key) do
    not MapSet.member?(state.joined_channels, key) and
      MapSet.member?(state.pending_joins, key) and
      not MapSet.member?(Map.get(state, :sent_joins, MapSet.new()), key)
  end

  defp cancel_queued_part(state, channel, key) do
    case Chat.confirm_channel_left(state.connection, channel, Targets.casemapping(state)) do
      {:ok, _membership} ->
        {:ok, %{state | pending_joins: MapSet.delete(state.pending_joins, key)}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp transmit_part(%{client: nil} = state, _channel, _reason, _key),
    do: {{:error, :not_connected}, state}

  defp transmit_part(state, channel, reason, key) do
    case Ircxd.Client.part(state.client, channel, reason) do
      :ok -> {:ok, %{state | pending_joins: MapSet.delete(state.pending_joins, key)}}
      error -> {error, state}
    end
  end

  defp maybe_quit(nil, _reason), do: :ok
  defp maybe_quit(client, reason), do: Ircxd.Client.quit(client, reason)

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error
end
