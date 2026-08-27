defmodule Ircpipe.Irc.Session.EventPipelineTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, MessageHistory}
  alias Ircpipe.Irc.Session.EventPipeline
  alias Ircxd.Client.Event

  test "routes an ordinary canonical event to its legacy representation" do
    state = %{pending_commands: %{}, marker: :preserved}
    legacy = {:typing, %{target: "#elixir"}}
    event = struct(Event, name: :typing, derivative?: true, legacy: legacy)

    assert EventPipeline.handle(state, event) == {:legacy, legacy, state}
  end

  test "handles legacy-suppressed command output without routing it again" do
    state = %{
      pending_commands: %{"motd-1" => %{command: "MOTD"}},
      marker: :preserved
    }

    event =
      struct(Event,
        name: :motd,
        derivative?: true,
        legacy: {:motd, %{text: "hello"}}
      )

    assert EventPipeline.handle(state, event) == {:handled, state}
  end

  test "handles a JOIN failure without routing its legacy event twice" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "event pipeline",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    state = %{
      active_casemapping: :ascii,
      connection: connection,
      pending_commands: %{},
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }

    event =
      struct(Event,
        name: :irc_error,
        payload: %{code: "473", target: "JOIN", reason: "Invite only"},
        derivative?: true,
        legacy: {:irc_error, %{code: "473", target: "JOIN", reason: "Invite only"}}
      )

    assert EventPipeline.handle(state, event) == {:handled, state}

    assert [%{body: "Invite only"}] =
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}")
  end
end
