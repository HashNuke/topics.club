defmodule TopicsClub.Irc.SessionLocator do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias Ircxd.Client.Info

  def via(%ServerConnection{user_id: user_id, id: id}) do
    {:via, Registry, {TopicsClub.Irc.SessionRegistry, {user_id, id}}}
  end

  def whereis(%ServerConnection{} = connection), do: GenServer.whereis(via(connection))

  def status(%ServerConnection{} = connection) do
    case whereis(connection) do
      nil ->
        "disconnected"

      _pid ->
        case GenServer.call(via(connection), :connection_info) do
          {:ok, %Info{registered?: true}} -> "connected"
          _reply -> "connecting"
        end
    end
  catch
    :exit, _reason -> "disconnected"
  end
end
