defmodule Ircpipe.Irc.Session.DepartureCommands do
  @moduledoc false

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session.{EventRecorder, Targets}

  def part(state, channel, reason) do
    key = Targets.key(state, channel)

    if queued_locally?(state, key) do
      cancel_queued_part(state, channel, key)
    else
      transmit_part(state, channel, reason, key)
    end
  end

  def quit(state, reason) do
    result = maybe_quit(state.client, reason)
    EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
    {normalize_result(result), state}
  end

  def quit_for_deletion(state) do
    result = maybe_quit(state.client, "connection deleted")
    {normalize_result(result), Map.put(state, :deleting?, true)}
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
