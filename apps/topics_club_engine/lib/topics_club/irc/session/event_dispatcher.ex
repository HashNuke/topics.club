defmodule TopicsClub.Irc.Session.EventDispatcher do
  @moduledoc false

  alias TopicsClub.Irc.Session.ChannelListEvents
  alias TopicsClub.Irc.Session.ConnectionEvents
  alias TopicsClub.Irc.Session.ConnectionIssue
  alias TopicsClub.Irc.Session.EventPipeline
  alias TopicsClub.Irc.Session.InboundMessageRouting
  alias TopicsClub.Irc.Session.JoinFailureEvents
  alias TopicsClub.Irc.Session.MembershipEvents
  alias TopicsClub.Irc.Session.ServerEvents
  alias TopicsClub.Irc.Session.UnhandledEvents
  alias Ircxd.Client.Event
  alias Ircxd.Message

  def dispatch(state, %Event{} = event) do
    case EventPipeline.handle(state, event) do
      {:handled, state} -> state
      {:legacy, legacy, state} -> dispatch(state, legacy)
    end
  end

  def dispatch(state, :registered), do: ConnectionEvents.registered(state)

  def dispatch(state, {:resumed, metadata}), do: ConnectionEvents.resumed(state, metadata)

  def dispatch(state, {:connect_error, reason}),
    do: ConnectionEvents.connect_error(state, reason)

  def dispatch(state, :disconnected), do: ConnectionEvents.disconnected(state)

  def dispatch(state, {:reconnecting, payload}), do: ConnectionEvents.reconnecting(state, payload)

  def dispatch(state, {:connected, _metadata}),
    do: Map.put(state, :wirekeeper_node_down?, false)

  def dispatch(state, {:disconnect, %{reason: {:wirekeeper_node_down, _node}}}),
    do: Map.put(state, :wirekeeper_node_down?, true)

  def dispatch(state, {:privmsg, %{target: _target, nick: _nick, body: _body} = payload}),
    do: InboundMessageRouting.privmsg(state, payload)

  def dispatch(state, {:notice, %{target: _target, nick: _nick, body: _body} = payload}),
    do: InboundMessageRouting.notice(state, payload)

  def dispatch(state, {event, %{text: _text} = payload})
      when event in [
             :welcome,
             :your_host,
             :server_created,
             :motd_start,
             :motd,
             :motd_end,
             :motd_missing
           ],
      do: ServerEvents.handle(event, state, payload)

  def dispatch(state, {:server_info, payload}),
    do: ServerEvents.handle(:server_info, state, payload)

  def dispatch(state, {:names, %{channel: _channel, names: _names} = payload}),
    do: MembershipEvents.handle(:names, state, payload)

  def dispatch(state, {:names_end, %{channel: _channel} = payload}),
    do: MembershipEvents.handle(:names_end, state, payload)

  def dispatch(state, {:join, %{channel: _channel, nick: _nick} = payload}),
    do: MembershipEvents.handle(:join, state, payload)

  def dispatch(state, {:part, %{channel: _channel, nick: _nick} = payload}),
    do: MembershipEvents.handle(:part, state, payload)

  def dispatch(state, {:quit, %{nick: _nick} = payload}),
    do: MembershipEvents.handle(:quit, state, payload)

  def dispatch(state, {:nick, %{old_nick: _old_nick, new_nick: _new_nick} = payload}),
    do: MembershipEvents.handle(:nick, state, payload)

  def dispatch(state, {:away, %{nick: _nick} = payload}),
    do: MembershipEvents.handle(:away, state, payload)

  def dispatch(state, {:mode, %{target: _target} = payload}),
    do: MembershipEvents.handle(:mode, state, payload)

  def dispatch(
        state,
        {:kick, %{channel: _channel, nick: _nick, target_nick: _target_nick} = payload}
      ),
      do: MembershipEvents.handle(:kick, state, payload)

  def dispatch(state, {:topic, %{channel: _channel, nick: _nick, topic: _topic} = payload}),
    do: MembershipEvents.handle(:topic, state, payload)

  def dispatch(state, {:irc_error, payload}) do
    case ConnectionIssue.from_irc_error(payload, state.connection) do
      nil -> JoinFailureEvents.irc_error(state, payload)
      _issue when state.registered? -> JoinFailureEvents.irc_error(state, payload)
      issue -> ConnectionEvents.require_human(state, issue)
    end
  end

  def dispatch(state, {:standard_reply, %{type: :fail, command: "JOIN"} = payload}),
    do: JoinFailureEvents.standard_reply(state, payload)

  def dispatch(state, {:nick_in_use, payload}) do
    if state.registered? do
      ServerEvents.handle(:nick_in_use, state, payload)
    else
      issue = ConnectionIssue.nickname_in_use(payload, state.connection)
      ConnectionEvents.require_human(state, issue)
    end
  end

  def dispatch(state, {:sasl_failure, payload}) do
    issue = ConnectionIssue.sasl_failure(payload, state.connection)
    ConnectionEvents.require_human(state, issue)
  end

  def dispatch(state, {event_name, _payload} = event)
      when event_name in [:list_start, :list_entry, :list_end] do
    case ChannelListEvents.handle_irc(state, event) do
      {:handled, state} -> state
      :unhandled -> UnhandledEvents.handle(state, event)
    end
  end

  def dispatch(state, {:raw, %Message{command: command} = message})
      when byte_size(command) == 3,
      do: ServerEvents.handle(:raw, state, message)

  def dispatch(state, event), do: UnhandledEvents.handle(state, event)
end
