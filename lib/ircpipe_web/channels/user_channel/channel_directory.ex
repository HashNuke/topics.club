defmodule IrcpipeWeb.UserChannel.ChannelDirectory do
  @moduledoc false

  alias Ircpipe.Irc.Session

  def fetch(connection) do
    case list_channels(connection) do
      {:ok, channels} ->
        {:ok,
         %{
           server_connection_id: connection.id,
           server_name: connection.name,
           server_host: connection.host,
           channels: channels
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_channels(connection) do
    Session.list_channels(connection)
  catch
    :exit, _reason -> {:error, :not_connected}
  end
end
