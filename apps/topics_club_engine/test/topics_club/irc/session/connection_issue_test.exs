defmodule TopicsClub.Irc.Session.ConnectionIssueTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.ConnectionIssue

  @connection %ServerConnection{
    host: "irc.example.test",
    port: 6697,
    nickname: "bad.nick@example"
  }

  test "turns an invalid nickname reply into a nickname remedy" do
    issue =
      ConnectionIssue.from_irc_error(
        %{code: "432", reason: "Erroneous Nickname"},
        @connection
      )

    assert issue.code == "invalid_nickname"
    assert issue.edit_focus == "nickname"
    assert issue.attempted_nickname == "bad.nick@example"

    assert issue.summary ==
             "Use a random nickname and reconnect now, or edit the connection to choose one yourself."
  end

  test "turns a nickname collision into an actionable nickname remedy" do
    issue =
      ConnectionIssue.nickname_in_use(
        %{attempted: "taken", reason: "Nickname is already in use"},
        @connection
      )

    assert issue.title == "Nickname is already in use"

    assert issue.summary ==
             "Use a random nickname and reconnect now, or edit the connection to choose one yourself."

    assert issue.edit_focus == "nickname"
  end

  test "turns SASL failures into a credential remedy without storing secrets" do
    issue = ConnectionIssue.sasl_failure(%{code: "904"}, @connection)

    assert issue.code == "authentication_failed"
    assert issue.edit_focus == "credentials"
    assert issue.irc_code == "904"
    refute Map.has_key?(issue, :password)
  end

  test "leaves channel-specific IRC errors to their existing handler" do
    assert ConnectionIssue.from_irc_error(
             %{code: "473", reason: "Invite only"},
             @connection
           ) == nil
  end

  test "provides connection remedies after retries are exhausted" do
    issue = ConnectionIssue.retries_exhausted(:econnrefused, @connection)

    assert issue.code == "connection_failed"
    assert issue.edit_focus == "connection"
    assert issue.host == "irc.example.test"
    assert issue.port == 6697
    assert issue.technical_details == ":econnrefused"
  end
end
