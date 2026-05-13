defmodule Ircpipe.ChatTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Message

  test "prunes messages older than the user's retention window after inbound persistence" do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Chat.update_retention_days(user, 1)

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    expired =
      %Message{
        user_id: user.id,
        server_connection_id: connection.id,
        channel_membership_id: membership.id
      }
      |> Message.changeset(%{
        kind: "message",
        nick: "akash",
        body: "old",
        occurred_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
      })
      |> Repo.insert!()

    Chat.record_inbound_message(connection, "#elixir", "akash", "new")

    assert is_nil(Repo.get(Message, expired.id))
    assert [%Message{body: "new"}] = Chat.list_messages(user, membership.id)
  end
end
