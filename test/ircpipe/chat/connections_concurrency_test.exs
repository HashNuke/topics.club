defmodule Ircpipe.Chat.ConnectionsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ircpipe.Accounts.User
  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    ChannelJoinRequest,
    ConnectionDeletion,
    ConnectionEndpoint,
    Connections,
    ServerConnection
  }

  alias Ircpipe.Repo

  test "concurrent endpoint discovery serializes equivalent port representations" do
    user = unboxed(fn -> AccountsFixtures.user_fixture() end)
    barrier_ref = make_ref()

    previous_barrier =
      Application.get_env(:ircpipe_web, :connection_endpoint_create_barrier)

    Application.put_env(
      :ircpipe_web,
      :connection_endpoint_create_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_barrier(previous_barrier)

      unboxed(fn ->
        User
        |> where([user], user.id == ^user.id)
        |> Repo.delete_all()
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    ports = [6697, "6697", "06697", "+6697", 6697, "06697", "+6697", "6697"]

    consumer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        supervisor
        |> Task.Supervisor.async_stream_nolink(
          Enum.with_index(ports, 1),
          fn {port, attempt} ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              ConnectionEndpoint.create_or_get(user, %{
                "name" => "discovery-#{attempt}",
                "host" => " IRC.Concurrent.Test ",
                "port" => port
              })
            after
              :ok = Sandbox.checkin(Repo)
            end
          end,
          max_concurrency: length(ports),
          timeout: :infinity
        )
        |> Enum.to_list()
      end)

    contenders = await_contenders(length(ports), barrier_ref, user.id, [])
    Enum.each(contenders, &send(&1, {:start_connection_endpoint_lock, barrier_ref}))

    assert_receive {:connection_endpoint_create_paused, first_creator, ^barrier_ref, user_id,
                    "irc.concurrent.test", 6697},
                   5_000

    assert user_id == user.id

    refute_receive {:connection_endpoint_create_paused, _other_creator, ^barrier_ref, _, _, _},
                   100

    send(first_creator, {:continue_connection_endpoint_create, barrier_ref})

    connection_ids =
      consumer
      |> Task.await(:infinity)
      |> Enum.map(fn {:ok, {:ok, connection}} -> connection.id end)

    assert [_connection_id] = Enum.uniq(connection_ids)

    assert 1 ==
             unboxed(fn ->
               ServerConnection
               |> where([connection], connection.user_id == ^user.id)
               |> Repo.aggregate(:count)
             end)
  end

  test "connection deletion locks out a concurrent channel join" do
    user = unboxed(fn -> AccountsFixtures.user_fixture() end)

    connection =
      unboxed(fn ->
        {:ok, connection} =
          Connections.create(user, %{
            "name" => "delete race",
            "host" => "irc.delete-race.test",
            "nickname" => "mira"
          })

        connection
      end)

    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe_engine, :connection_delete_after_lock_barrier)

    Application.put_env(
      :ircpipe_engine,
      :connection_delete_after_lock_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_engine_env(:connection_delete_after_lock_barrier, previous_barrier)

      unboxed(fn ->
        User
        |> where([user], user.id == ^user.id)
        |> Repo.delete_all()
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    delete_task =
      unboxed_task(supervisor, fn -> ConnectionDeletion.delete(user, connection.id) end)

    assert_receive {:connection_delete_paused, delete_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id

    test_pid = self()

    join_task =
      unboxed_task(supervisor, fn ->
        send(test_pid, {:connection_join_attempting, self(), barrier_ref})
        ChannelJoinRequest.request(user, connection, "#late")
      end)

    assert_receive {:connection_join_attempting, _join_pid, ^barrier_ref}
    refute Task.yield(join_task, 100)

    send(delete_pid, {:continue_connection_delete, barrier_ref})

    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
    assert {:error, :connection_not_found} = Task.await(join_task, 5_000)

    assert nil == unboxed(fn -> Repo.get(ServerConnection, connection.id) end)
  end

  defp await_contenders(0, _barrier_ref, _user_id, contenders), do: contenders

  defp await_contenders(remaining, barrier_ref, user_id, contenders) do
    assert_receive {:connection_endpoint_lock_ready, contender, ^barrier_ref, ^user_id,
                    "irc.concurrent.test", 6697},
                   5_000

    await_contenders(remaining - 1, barrier_ref, user_id, [contender | contenders])
  end

  defp unboxed(callback) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      callback.()
    after
      :ok = Sandbox.checkin(Repo)
    end
  end

  defp unboxed_task(supervisor, callback) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        callback.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  defp restore_barrier(nil) do
    Application.delete_env(:ircpipe_web, :connection_endpoint_create_barrier)
  end

  defp restore_barrier(previous_barrier) do
    Application.put_env(:ircpipe_web, :connection_endpoint_create_barrier, previous_barrier)
  end

  defp restore_engine_env(key, nil), do: Application.delete_env(:ircpipe_engine, key)
  defp restore_engine_env(key, value), do: Application.put_env(:ircpipe_engine, key, value)
end
