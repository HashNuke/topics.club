defmodule TopicsClub.Irc.Session.MembershipEvents do
  @moduledoc false

  alias TopicsClub.Chat

  alias TopicsClub.Chat.{
    ChannelPartLifecycle,
    ConnectionLifecycle,
    DirectMessageRenamer,
    Presence
  }

  alias TopicsClub.Irc.EventFormatting

  alias TopicsClub.Irc.Session.{
    EventRecorder,
    Identity,
    JoinLifecycle,
    Targets,
    WirekeeperIngestion
  }

  def handle(:names, state, %{channel: channel, names: names}) do
    normalized = Targets.key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    buffered_names = Map.get(names_buffers, normalized, []) ++ names

    state = Map.put(state, :names_buffers, Map.put(names_buffers, normalized, buffered_names))

    if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
         Identity.listed?(names, state.connection.nickname, Targets.casemapping(state)) do
      JoinLifecycle.mark_joined(state, channel)
    else
      state
    end
  end

  def handle(:names_end, state, %{channel: channel}) do
    normalized = Targets.key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    names = Map.get(names_buffers, normalized, [])

    if names != [] do
      state.connection
      |> Presence.sync(channel, names, Targets.casemapping(state))
      |> WirekeeperIngestion.observe_result()
    end

    state
    |> Map.put(:names_buffers, Map.delete(names_buffers, normalized))
    |> JoinLifecycle.mark_joined_from_names(channel, names)
  end

  def handle(:join, state, %{channel: channel, nick: nick} = payload) do
    self? = Identity.source_self?(state, payload, nick)

    join_confirmed? =
      if self? do
        result =
          Chat.confirm_channel_join(
            state.connection,
            channel,
            Targets.casemapping(state),
            "connected"
          )

        WirekeeperIngestion.observe_result(result)

        case result do
          {:ok, _membership} -> true
          {:error, _reason} -> false
        end
      else
        true
      end

    state.connection
    |> Presence.diff(
      channel,
      %{action: "join", user: %{nick: nick, role: "user", status: "online"}},
      Targets.casemapping(state)
    )
    |> WirekeeperIngestion.observe_result()

    EventRecorder.channel_line(state, channel, "join", nick, "#{nick} joined #{channel}.")

    if self? and join_confirmed?, do: JoinLifecycle.mark_joined(state, channel), else: state
  end

  def handle(:part, state, %{channel: channel, nick: nick} = payload) do
    self? = Identity.source_self?(state, payload, nick)

    state.connection
    |> Presence.diff(channel, %{action: "part", nick: nick}, Targets.casemapping(state))
    |> WirekeeperIngestion.observe_result()

    EventRecorder.channel_line(state, channel, "part", nick, "#{nick} left #{channel}.")

    if self? do
      result =
        ChannelPartLifecycle.confirm(state.connection, channel, Targets.casemapping(state))

      WirekeeperIngestion.observe_result(result)

      case result do
        {:ok, _membership} ->
          %{
            state
            | joined_channels: MapSet.delete(state.joined_channels, Targets.key(state, channel))
          }

        {:error, _reason} ->
          state
      end
    else
      state
    end
  end

  def handle(:quit, state, %{nick: nick}) do
    EventRecorder.present_nick_line(state, "quit", nick, fn _membership ->
      "#{nick} quit."
    end)

    state.connection
    |> Presence.diff(nil, %{action: "quit", nick: nick}, Targets.casemapping(state))
    |> WirekeeperIngestion.observe_result()

    state
  end

  def handle(:nick, state, %{old_nick: old_nick, new_nick: new_nick} = payload) do
    self? = Identity.source_self?(state, payload, old_nick)

    EventRecorder.present_nick_line(
      state,
      "nick",
      old_nick,
      new_nick,
      fn _membership -> "#{old_nick} is now #{new_nick}." end
    )

    state.connection
    |> Presence.diff(
      nil,
      %{action: "nick", old_nick: old_nick, new_nick: new_nick},
      Targets.casemapping(state)
    )
    |> WirekeeperIngestion.observe_result()

    unless self? do
      state.connection
      |> DirectMessageRenamer.rename(
        old_nick,
        new_nick,
        EventFormatting.sender_metadata(payload),
        Targets.casemapping(state)
      )
      |> WirekeeperIngestion.observe_result()
    end

    if self? do
      result = ConnectionLifecycle.update_nickname(state.connection, new_nick, "connected")
      WirekeeperIngestion.observe_result(result)

      case result do
        {:ok, connection} -> %{state | connection: connection}
        {:error, _changeset} -> state
      end
    else
      state
    end
  end

  def handle(:away, state, %{nick: nick} = payload) do
    status = if Map.get(payload, :away?), do: "away", else: "online"

    state.connection
    |> Presence.diff(
      nil,
      %{action: "away", nick: nick, status: status},
      Targets.casemapping(state)
    )
    |> WirekeeperIngestion.observe_result()

    state
  end

  def handle(:mode, state, %{target: target} = payload) do
    if Targets.channel?(state, target) do
      payload
      |> EventFormatting.mode_presence_diffs(Targets.isupport(state))
      |> Enum.each(
        &(state.connection
          |> Presence.diff(target, &1, Targets.casemapping(state))
          |> WirekeeperIngestion.observe_result())
      )

      EventRecorder.channel_line(
        state,
        target,
        "mode",
        Map.get(payload, :nick),
        EventFormatting.mode_body(payload)
      )
    else
      EventRecorder.server_line(state.connection, EventFormatting.mode_body(payload), "mode")
    end

    state
  end

  def handle(
        :kick,
        state,
        %{channel: channel, nick: nick, target_nick: target_nick} = payload
      ) do
    target_self? = Identity.event_self?(state, payload, :target_self?, target_nick)

    state.connection
    |> Presence.diff(channel, %{action: "part", nick: target_nick}, Targets.casemapping(state))
    |> WirekeeperIngestion.observe_result()

    EventRecorder.channel_line(
      state,
      channel,
      "kick",
      nick,
      EventFormatting.kick_body(payload)
    )

    if target_self? do
      result =
        ChannelPartLifecycle.confirm(state.connection, channel, Targets.casemapping(state))

      WirekeeperIngestion.observe_result(result)

      case result do
        {:ok, _membership} ->
          %{
            state
            | joined_channels: MapSet.delete(state.joined_channels, Targets.key(state, channel))
          }

        {:error, _reason} ->
          state
      end
    else
      state
    end
  end

  def handle(:topic, state, %{channel: channel, nick: nick, topic: topic}) do
    EventRecorder.channel_line(
      state,
      channel,
      "topic",
      nick,
      "#{nick} changed the topic to: #{topic}"
    )

    state
  end
end
