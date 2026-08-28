defmodule TopicsClub.Irc.Session.CommandTargetCorrelation do
  @moduledoc false

  alias TopicsClub.Irc.Session.Targets
  alias Ircxd.Message

  def for_message(state, %Message{command: command, params: [targets | _rest]})
      when command in ["JOIN", "PART", "PRIVMSG", "NOTICE"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize(state, &1))
  end

  def for_message(state, %Message{command: command, params: [target | _rest]})
      when command in ["NICK", "TOPIC", "MODE", "KICK", "INVITE"] do
    [normalize(state, target)]
  end

  def for_message(state, %Message{command: command, params: params})
      when command in ["ISON", "USERHOST"] do
    Enum.map(params, &normalize(state, &1))
  end

  def for_message(state, %Message{command: "WHOIS", params: params}) do
    case List.last(params) do
      target when is_binary(target) -> [normalize(state, target)]
      _target -> []
    end
  end

  def for_message(state, %Message{command: command, params: [targets | _rest]})
      when command in ["LIST", "NAMES", "WHO", "WHOWAS"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize(state, &1))
  end

  def for_message(_state, %Message{}), do: []

  def matches?(state, target, targets) when is_binary(target),
    do: normalize(state, target) in targets

  def matches?(_state, _target, _targets), do: false

  defp normalize(state, target) do
    if Targets.channel?(state, target),
      do: Targets.key(state, target),
      else: Targets.normalize(state, target)
  end
end
