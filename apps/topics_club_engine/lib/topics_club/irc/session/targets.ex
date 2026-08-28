defmodule TopicsClub.Irc.Session.Targets do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Identifier
  alias Ircxd.Client.Info
  alias Ircxd.ISupport

  def channel(
        %{client_info: %Info{isupport: isupport}, isupport_received?: true},
        target
      )
      when is_binary(target) do
    cond do
      ISupport.status_target?(isupport, target) -> String.slice(target, 1..-1//1)
      ISupport.channel?(isupport, target) -> target
      true -> nil
    end
  end

  def channel(_state, <<prefix, _rest::binary>> = target) when prefix in [?#, ?&, ?+, ?!],
    do: target

  def channel(_state, _target), do: nil

  def channel?(state, target), do: not is_nil(channel(state, target))

  def isupport(%{client_info: %{isupport: isupport}}) when is_map(isupport), do: isupport
  def isupport(_state), do: %{}

  def normalize(
        %{client_info: %Info{casemapping: mapping}, isupport_received?: true},
        identifier
      ),
      do: Ircxd.Casemapping.normalize(identifier, mapping)

  def normalize(state, identifier),
    do: Ircxd.Casemapping.normalize(identifier, casemapping(state))

  def casemapping(%{active_casemapping: mapping}) when not is_nil(mapping), do: mapping
  def casemapping(%{connection: %ServerConnection{casemapping: "ascii"}}), do: :ascii

  def casemapping(%{connection: %ServerConnection{casemapping: "strict_rfc1459"}}),
    do: :strict_rfc1459

  def casemapping(%{connection: %ServerConnection{casemapping: "rfc1459"}}), do: :rfc1459
  def casemapping(_state), do: :ascii

  def key(state, target) do
    Identifier.key(channel(state, target) || target, casemapping(state))
  end
end
