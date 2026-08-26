defmodule IrcpipeWeb.UserChannel.ChannelDirectoryTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Chat.ServerConnection
  alias IrcpipeWeb.UserChannel.ChannelDirectory

  test "reports a disconnected server without leaking the session exit" do
    connection = %ServerConnection{id: System.unique_integer([:positive])}

    assert {:error, :not_connected} = ChannelDirectory.fetch(connection)
  end
end
