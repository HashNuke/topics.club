defmodule TopicsClub.Irc.Session.CommandLifecyclePersistenceTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.{CommandMessages, Connections, Message}

  alias TopicsClub.Irc.Session.{CommandLifecycle, WirekeeperIngestion}
  alias TopicsClub.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "command lifecycle persistence",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    {:ok, invocation} =
      CommandMessages.record(
        connection,
        "server:#{connection.id}",
        "MOTD",
        %{command_id: "motd-1", command: "MOTD", command_status: "sent"}
      )

    %{connection: connection, invocation: invocation}
  end

  test "a command result persistence exception marks the Wirekeeper event failed", context do
    event = Ircxd.Client.Event.from_legacy!({:motd, %{text: "Welcome"}})
    timer = Process.send_after(self(), :unused_command_timeout, 60_000)

    pending = %{
      command_id: "motd-1",
      command: "MOTD",
      targets: [],
      spec: %{result_events: [:motd], terminal_events: [:end_of_motd]},
      invocation: context.invocation,
      buffer_id: "channel:999999999",
      labeled?: false,
      collected_results: [],
      timer: timer
    }

    state =
      %{
        connection: context.connection,
        pending_commands: %{"motd-1" => pending},
        active_casemapping: :ascii
      }
      |> WirekeeperIngestion.initialize()
      |> WirekeeperIngestion.enqueue(%{generation: "generation-1", sequence: 1})

    :ok = WirekeeperIngestion.begin_event(state, event)
    returned = CommandLifecycle.process_event(state, event)

    assert WirekeeperIngestion.event_failed?()
    assert Map.has_key?(returned.pending_commands, "motd-1")

    returned = WirekeeperIngestion.finish_event(returned)
    assert WirekeeperIngestion.failed?(returned)
    Process.cancel_timer(timer)
  end

  test "failed disconnect status persistence keeps the command retryable", context do
    timer = Process.send_after(self(), :unused_command_timeout, 60_000)

    pending = %{
      invocation: context.invocation,
      timer: timer
    }

    context.connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    returned =
      CommandLifecycle.fail_all(
        %{pending_commands: %{"motd-1" => pending}},
        "Connection closed before completion."
      )

    assert Process.read_timer(timer) == false
    assert %{timer: retry_timer} = returned.pending_commands["motd-1"]
    assert is_integer(Process.read_timer(retry_timer))
    assert Repo.get!(Message, context.invocation.id).metadata["command_status"] == "sent"
    Process.cancel_timer(retry_timer)
  end
end
