defmodule TopicsClub.Irc.Session.JoinReconciliationTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.JoinReconciliation
  alias Ircxd.Client.Event

  test "classifies JOIN membership failure events" do
    join_error =
      struct(Event,
        name: :irc_error,
        payload: %{code: "473", target: "#private"}
      )

    join_fail =
      struct(Event,
        name: :standard_reply,
        payload: %{type: :fail, command: "JOIN"}
      )

    other_fail =
      struct(Event,
        name: :standard_reply,
        payload: %{type: :fail, command: "WHOIS"}
      )

    assert JoinReconciliation.failure_event?(join_error)
    assert JoinReconciliation.failure_event?(join_fail)
    refute JoinReconciliation.failure_event?(other_fail)
  end

  test "reports whether any managed JOIN command is pending" do
    refute JoinReconciliation.pending_command?(%{pending_commands: %{}})

    assert JoinReconciliation.pending_command?(%{
             pending_commands: %{
               "join-1" => pending("JOIN", 2),
               "whois-1" => pending("WHOIS", 1)
             }
           })
  end

  test "ignores a labeled channel error that does not identify a pending JOIN" do
    state = base_state(%{"join-1" => pending("JOIN", 1, ["#wanted"])})

    event =
      struct(Event,
        name: :irc_error,
        label: "unknown-command",
        payload: %{code: "403", target: "#wanted", reason: "No such channel"}
      )

    assert JoinReconciliation.reconcile_event(state, event) == state
  end

  test "ignores legacy JOIN errors for targets that are not pending" do
    state = base_state(%{})

    assert JoinReconciliation.reconcile_legacy_error(state, %{
             code: "403",
             target: "#other",
             reason: "No such channel"
           }) == state

    assert JoinReconciliation.reconcile_legacy_error(state, %{
             code: "461",
             target: "WHO",
             reason: "Not enough parameters"
           }) == state
  end

  defp base_state(pending_commands) do
    %{
      active_casemapping: :ascii,
      connection: %ServerConnection{},
      pending_commands: pending_commands,
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }
  end

  defp pending(command, id, targets \\ []) do
    %{
      command: command,
      invocation: %{id: id},
      labeled?: false,
      targets: targets
    }
  end
end
