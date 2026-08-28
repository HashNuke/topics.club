defmodule TopicsClub.Chat.PresenceDiff do
  @moduledoc false

  alias TopicsClub.Irc.Identifier

  def canonicalize(%{action: "join", user: user} = diff, casemapping) do
    put_in(diff, [:user, :nick_key], Identifier.key(value(user, :nick), casemapping))
  end

  def canonicalize(%{action: action, nick: nick} = diff, casemapping)
      when action in ["part", "quit", "away", "role"] and is_binary(nick) do
    Map.put(diff, :nick_key, Identifier.key(nick, casemapping))
  end

  def canonicalize(
        %{action: "nick", old_nick: old_nick, new_nick: new_nick} = diff,
        casemapping
      )
      when is_binary(old_nick) and is_binary(new_nick) do
    diff
    |> Map.put(:old_nick_key, Identifier.key(old_nick, casemapping))
    |> Map.put(:new_nick_key, Identifier.key(new_nick, casemapping))
  end

  def canonicalize(diff, _casemapping), do: diff

  defp value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
