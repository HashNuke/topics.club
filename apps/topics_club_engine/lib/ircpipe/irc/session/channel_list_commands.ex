defmodule Ircpipe.Irc.Session.ChannelListCommands do
  @moduledoc false

  alias Ircpipe.Chat.ServerConnectionLock
  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Irc.Session.ChannelListRequest

  def request(%{registered?: false} = state, _from) do
    {:reply, {:error, :not_connected}, state}
  end

  def request(%{channel_list_request: request} = state, _from) when not is_nil(request) do
    {:reply, {:error, :list_in_progress}, state}
  end

  def request(state, from) do
    case ConnectionLock.run_serialized(state.connection, fn -> request_active(state, from) end) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      result -> result
    end
  end

  defp request_active(%{client: nil} = state, _from) do
    {:reply, {:error, :not_connected}, state}
  end

  defp request_active(state, from) do
    with :ok <- ServerConnectionLock.ensure_active(state.connection.id),
         :ok <- Ircxd.Client.list(state.client) do
      {:noreply, %{state | channel_list_request: ChannelListRequest.new(from)}}
    else
      error -> {:reply, error, state}
    end
  end
end
