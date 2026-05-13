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

  test "records server buffer messages without a channel membership" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %Message{channel_membership_id: nil, kind: "system", body: "Connected"}} =
             Chat.record_server_message(connection, "Connected")

    assert_receive {:buffer_message,
                    %{
                      type: "buffer:message",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: "server:" <> _,
                      server_connection_id: connection_id,
                      channel_membership_id: nil,
                      kind: "system",
                      body: "Connected"
                    }}

    assert connection_id == connection.id

    assert [%Message{body: "Connected"}] =
             Chat.list_buffer_messages(user, "server:#{connection.id}")
  end

  test "broadcasts inbound channel messages as normalized buffer events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    Chat.record_inbound_message(connection, "#elixir", "akash", "hello")

    assert_receive {:buffer_message,
                    %{
                      type: "buffer:message",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id,
                      channel: "#elixir",
                      body: "hello"
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id
  end
end
