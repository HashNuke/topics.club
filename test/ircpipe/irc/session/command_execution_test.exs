defmodule Ircpipe.Irc.Session.CommandExecutionTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, MessageHistory}
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.Session.CommandExecution

  test "validates managed command targets against joined and pending state" do
    state = %{
      joined_channels: MapSet.new(["#joined"]),
      pending_joins: MapSet.new(["#pending"]),
      active_casemapping: :ascii
    }

    assert :ok =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "PRIVMSG", params: ["#joined", "hello"]}
             })

    assert {:error, :not_joined} =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "PRIVMSG", params: ["#missing", "hello"]}
             })

    assert {:error, :already_pending} =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "JOIN", params: ["#pending"]}
             })
  end

  test "rejects invalid command ids before persistence" do
    context = execution_context()
    assert {:ok, intent} = CommandRegistry.resolve("WHOIS mira", %{isupport: %{}})

    assert {{:error, %{code: "invalid_command_id"}}, returned} =
             CommandExecution.execute(
               context.state,
               intent,
               "invalid id",
               "server:#{context.connection.id}"
             )

    assert returned == context.state
    assert messages(context) == []
  end

  test "marks a persisted invocation failed when transmission fails" do
    context = execution_context()
    assert {:ok, intent} = CommandRegistry.resolve("WHOIS mira", %{isupport: %{}})

    assert {{:error, %{code: "closed"}}, returned} =
             CommandExecution.execute(
               context.state,
               intent,
               "whois-failure",
               "server:#{context.connection.id}"
             )

    assert returned == context.state
    assert [invocation] = messages(context)
    assert invocation.kind == "command"
    assert invocation.body == "WHOIS mira"
    assert invocation.metadata["command_id"] == "whois-failure"
    assert invocation.metadata["command_status"] == "failed"
    assert invocation.metadata["error"] == ":closed"
  end

  defp execution_context do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "command execution",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    client = start_supervised!({Ircpipe.FailingIrcClient, :closed})

    state = %{
      connection: connection,
      client: client,
      client_info: nil,
      registered?: true,
      pending_commands: %{},
      pending_joins: MapSet.new(),
      joined_channels: MapSet.new(),
      sent_joins: MapSet.new(),
      active_casemapping: :ascii
    }

    %{connection: connection, state: state, user: user}
  end

  defp messages(context) do
    MessageHistory.list_buffer_messages(
      context.user,
      "server:#{context.connection.id}"
    )
  end
end
