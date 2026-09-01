defmodule TopicsClub.Irc.Session.JoinLifecycle do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Chat
  alias TopicsClub.Chat.{ChannelMembership, ServerConnection, ServerConnectionLock}
  alias TopicsClub.Irc.{CommandRegistry, ConnectionLock, Identifier}
  alias TopicsClub.Irc.Session.{Identity, Targets}
  alias TopicsClub.Repo
  alias Ircxd.Client.Info

  @isupport_settle_timeout 100

  def validate(%{client_info: %Info{} = info, isupport_received?: true}, channel),
    do: CommandRegistry.validate_join_channel(channel, info)

  def validate(_state, channel),
    do: CommandRegistry.validate_join_channel_syntax(channel)

  def transmit(
        %{connection: %ServerConnection{id: id, user_id: user_id}} = state,
        channel
      )
      when is_integer(id) and is_integer(user_id) do
    case ConnectionLock.run_serialized(state.connection, fn ->
           with :ok <- ServerConnectionLock.ensure_active(state.connection.id) do
             transmit_active(state, channel)
           else
             {:error, reason} -> {{:error, reason}, state}
           end
         end) do
      {:error, reason} -> {{:error, reason}, state}
      result -> result
    end
  end

  def transmit(state, channel), do: transmit_active(state, channel)

  defp transmit_active(state, channel) do
    key = Targets.key(state, channel)

    if MapSet.member?(state.joined_channels, key) do
      {:sent, state}
    else
      result =
        case state do
          %{client: client, registered?: true, join_validation_ready?: true}
          when not is_nil(client) ->
            Ircxd.Client.join(client, channel)

          _state ->
            :queued
        end

      case normalize_result(result) do
        :ok ->
          {:sent,
           state
           |> Map.put(:pending_joins, MapSet.put(state.pending_joins, key))
           |> Map.put(:sent_joins, MapSet.put(Map.get(state, :sent_joins, MapSet.new()), key))}

        :queued ->
          {:queued, %{state | pending_joins: MapSet.put(state.pending_joins, key)}}

        error ->
          {error, state}
      end
    end
  end

  def mark_joined(state, channel) do
    normalized = Targets.key(state, channel)

    state
    |> Map.put(
      :pending_joins,
      MapSet.delete(Map.get(state, :pending_joins, MapSet.new()), normalized)
    )
    |> Map.put(
      :joined_channels,
      MapSet.put(Map.get(state, :joined_channels, MapSet.new()), normalized)
    )
    |> Map.put(:sent_joins, MapSet.delete(Map.get(state, :sent_joins, MapSet.new()), normalized))
  end

  def mark_joined_from_names(state, channel, names) do
    normalized = Targets.key(state, channel)

    if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
         Identity.listed?(names, state.connection.nickname, Targets.casemapping(state)) do
      mark_joined(state, channel)
    else
      state
    end
  end

  def schedule_flush(%{registered?: true, join_validation_ready?: false} = state) do
    _ = cancel_flush(state)
    token = make_ref()
    timer = Process.send_after(self(), {:flush_pending_joins, token}, @isupport_settle_timeout)
    %{state | join_flush_timer: {timer, token}}
  end

  def schedule_flush(state), do: state

  def cancel_flush(state) do
    case Map.get(state, :join_flush_timer) do
      {timer, _token} -> Process.cancel_timer(timer)
      _timer -> :ok
    end

    nil
  end

  def rekey(state, mapping) do
    state
    |> Map.update(:pending_joins, MapSet.new(), &rekey_channels(&1, mapping))
    |> Map.update(:joined_channels, MapSet.new(), &rekey_channels(&1, mapping))
    |> Map.update(:sent_joins, MapSet.new(), &rekey_channels(&1, mapping))
  end

  def restore(state, info) do
    mapping = Targets.casemapping(state)
    joined_channels = rekey_channels(state.joined_channels, mapping)

    pending_joins =
      state.connection
      |> persisted_channels(mapping)
      |> MapSet.difference(joined_channels)

    state
    |> Map.put(:client_info, info)
    |> Map.put(:pending_joins, pending_joins)
    |> Map.put(:joined_channels, joined_channels)
  end

  def restore_resumed(state) do
    mapping = Targets.casemapping(state)

    state
    |> Map.put(:pending_joins, persisted_channels(state.connection, mapping, ["pending"]))
    |> Map.put(:joined_channels, persisted_channels(state.connection, mapping, ["joined"]))
    |> Map.put(:sent_joins, MapSet.new())
  end

  def refresh_resumed_presence(%{client: client} = state) when is_pid(client) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^state.connection.id and
        membership.status == "joined"
    )
    |> Repo.all()
    |> Enum.each(fn membership ->
      _result = Ircxd.Client.names(client, membership.channel)
    end)

    state
  rescue
    DBConnection.ConnectionError -> state
    DBConnection.OwnershipError -> state
  catch
    :exit, _reason -> state
  end

  def refresh_resumed_presence(state), do: state

  def flush(state) do
    case ConnectionLock.run_serialized(state.connection, fn ->
           case ServerConnectionLock.ensure_active(state.connection.id) do
             :ok -> flush_active(state)
             {:error, _reason} -> state
           end
         end) do
      {:error, _reason} -> state
      flushed_state -> flushed_state
    end
  end

  defp flush_active(state) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^state.connection.id and membership.auto_join and
        membership.status in ["pending", "joined"]
    )
    |> Repo.all()
    |> Enum.reduce(state, fn membership, current_state ->
      channel = membership.channel
      key = Targets.key(current_state, channel)

      if MapSet.member?(current_state.joined_channels, key) or
           MapSet.member?(Map.get(current_state, :sent_joins, MapSet.new()), key) do
        current_state
      else
        with :ok <- validate(current_state, channel),
             :ok <- ServerConnectionLock.ensure_active(current_state.connection.id),
             :ok <- Ircxd.Client.join(current_state.client, channel) do
          current_state
          |> Map.put(:pending_joins, MapSet.put(current_state.pending_joins, key))
          |> Map.put(
            :sent_joins,
            MapSet.put(Map.get(current_state, :sent_joins, MapSet.new()), key)
          )
        else
          {:error, reason} ->
            if current_state.isupport_received? do
              Chat.reject_channel_join(
                current_state.connection,
                channel,
                reason,
                Targets.casemapping(current_state)
              )

              %{current_state | pending_joins: MapSet.delete(current_state.pending_joins, key)}
            else
              current_state
            end
        end
      end
    end)
    |> Map.put(:joins_flushed?, true)
  end

  def persisted_channels(connection, casemapping \\ :rfc1459)

  def persisted_channels(%ServerConnection{} = connection, casemapping) do
    persisted_channels(connection, casemapping, ["pending", "joined"])
  end

  defp persisted_channels(%ServerConnection{} = connection, casemapping, statuses) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^connection.id and membership.auto_join and
        membership.status in ^statuses
    )
    |> Repo.all()
    |> Enum.map(&Identifier.key(&1.channel, casemapping))
    |> MapSet.new()
  end

  defp rekey_channels(channels, casemapping) do
    channels
    |> Enum.map(&Identifier.key(&1, casemapping))
    |> MapSet.new()
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error
end
