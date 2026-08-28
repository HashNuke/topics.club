defmodule TopicsClub.Irc.Session.Identity do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.Targets
  alias Ircxd.Casemapping
  alias Ircxd.Client.Info

  def source_self?(state, payload, nick) do
    event_self?(state, payload, :source_self?, nick)
  end

  def event_self?(%{isupport_received?: true} = state, payload, key, nick) do
    Map.get(payload, key, self?(state, nick))
  end

  def event_self?(state, _payload, _key, nick), do: self?(state, nick)

  def self?(%{client_info: %Info{} = info, isupport_received?: true} = state, nick) do
    is_binary(info.current_nick) and is_binary(nick) and
      Casemapping.normalize(info.current_nick, Targets.casemapping(state)) ==
        Casemapping.normalize(nick, Targets.casemapping(state))
  end

  def self?(%{connection: connection}, nick) do
    is_binary(nick) and
      Casemapping.normalize(nick, stored_casemapping(connection)) ==
        Casemapping.normalize(connection.nickname, stored_casemapping(connection))
  end

  def self?(_state, _nick), do: false

  def listed?(names, nick, casemapping) when is_list(names) do
    Enum.any?(names, fn
      %{nick: listed_nick} -> same_nick?(listed_nick, nick, casemapping)
      %{"nick" => listed_nick} -> same_nick?(listed_nick, nick, casemapping)
      listed_nick when is_binary(listed_nick) -> same_nick?(listed_nick, nick, casemapping)
      _other -> false
    end)
  end

  def listed?(_names, _nick, _casemapping), do: false

  defp same_nick?(left, right, casemapping) when is_binary(left) and is_binary(right) do
    Casemapping.normalize(left, casemapping) == Casemapping.normalize(right, casemapping)
  end

  defp same_nick?(_left, _right, _casemapping), do: false

  defp stored_casemapping(%ServerConnection{casemapping: "rfc1459"}), do: :rfc1459
  defp stored_casemapping(%ServerConnection{casemapping: "strict_rfc1459"}), do: :strict_rfc1459
  defp stored_casemapping(_connection), do: :ascii
end
