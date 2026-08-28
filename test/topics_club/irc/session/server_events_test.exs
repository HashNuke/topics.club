defmodule TopicsClub.Irc.Session.ServerEventsTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.{Connections, MessageHistory}
  alias TopicsClub.Irc.Session.ServerEvents
  alias Ircxd.Message

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "server events",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    %{connection: connection, state: %{connection: connection}, user: user}
  end

  test "records registration and MOTD text with the correct kind", context do
    events = [
      {:welcome, %{text: "Welcome to ExampleNet"}},
      {:your_host, %{text: "Your host is irc.example.test"}},
      {:server_created, %{text: "This server was created today"}},
      {:motd_start, %{text: "Message of the day"}},
      {:motd, %{text: "Be kind"}},
      {:motd_end, %{text: "End of MOTD"}},
      {:motd_missing, %{text: "MOTD is missing"}}
    ]

    Enum.each(events, fn {event, payload} ->
      assert context.state == ServerEvents.handle(event, context.state, payload)
    end)

    assert [
             %{kind: "system", body: "Welcome to ExampleNet"},
             %{kind: "system", body: "Your host is irc.example.test"},
             %{kind: "system", body: "This server was created today"},
             %{kind: "notice", body: "Message of the day"},
             %{kind: "notice", body: "Be kind"},
             %{kind: "notice", body: "End of MOTD"},
             %{kind: "notice", body: "MOTD is missing"}
           ] = messages(context)
  end

  test "formats server information and nickname errors", context do
    assert context.state ==
             ServerEvents.handle(:server_info, context.state, %{
               server: "irc.example.test",
               version: "ircd-1.0",
               user_modes: "iosw",
               channel_modes: "bklimnpst"
             })

    assert context.state ==
             ServerEvents.handle(:nick_in_use, context.state, %{
               reason: "Nickname mira is already in use"
             })

    assert [
             %{
               kind: "notice",
               body: "irc.example.test ircd-1.0 user modes iosw channel modes bklimnpst"
             },
             %{kind: "error", body: "Nickname mira is already in use"}
           ] = messages(context)
  end

  test "records only numeric raw replies and keeps the final description", context do
    numeric = %Message{
      source: "irc.example.test",
      command: "799",
      params: ["mira", "opaque context", "A future server reply"]
    }

    non_numeric = %Message{
      source: "irc.example.test",
      command: "ABC",
      params: ["mira", "not a numeric"]
    }

    assert context.state == ServerEvents.handle(:raw, context.state, numeric)
    assert context.state == ServerEvents.handle(:raw, context.state, non_numeric)

    assert [message] = messages(context)
    assert message.kind == "notice"
    assert message.body == "IRC reply 799: A future server reply"
    assert message.metadata == %{"irc_event" => "raw", "numeric" => "799"}
  end

  defp messages(context) do
    MessageHistory.list_buffer_messages(
      context.user,
      "server:#{context.connection.id}"
    )
  end
end
