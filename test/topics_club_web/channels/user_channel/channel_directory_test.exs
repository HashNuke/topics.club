defmodule TopicsClubWeb.UserChannel.ChannelDirectoryTest do
  use TopicsClub.DataCase

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.Connections
  alias TopicsClubWeb.UserChannel.ChannelDirectory

  test "reports a disconnected server without leaking the session exit" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "offline",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert {:error, :not_connected} = ChannelDirectory.fetch(user, connection)
  end
end
