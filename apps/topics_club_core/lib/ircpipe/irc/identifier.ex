defmodule Ircpipe.Irc.Identifier do
  @moduledoc false

  alias Ircxd.Casemapping

  def key(identifier, casemapping \\ :rfc1459) do
    Casemapping.normalize(identifier, casemapping)
  end

  def valid_nick?(nick, isupport \\ %{})

  def valid_nick?(nick, isupport) when is_binary(nick) and is_map(isupport) do
    max_length = Ircxd.ISupport.length_limit(isupport, "NICKLEN") || 128

    String.length(nick) <= max_length and
      String.match?(nick, ~r/^[A-Za-z_\[\]\\`^{}|][A-Za-z0-9_\-\[\]\\`^{}|]*$/)
  end

  def valid_nick?(_nick, _isupport), do: false
end
