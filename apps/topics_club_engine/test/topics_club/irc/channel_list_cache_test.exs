defmodule TopicsClub.Irc.ChannelListCacheTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.ChannelListCache

  test "caches one saved connection's channel list for 24 hours" do
    {cache, clock, _task_supervisor} = start_cache()
    connection = connection(1, 10, "IRC.Example.COM.")
    channels = [%{channel: "#elixir", users: 42, topic: "Elixir"}]

    assert {:ok, ^channels} =
             ChannelListCache.fetch(connection, fn -> {:ok, channels} end, server: cache)

    assert {:ok, ^channels} =
             ChannelListCache.fetch(
               connection,
               fn -> flunk("the unexpired list should be reused") end,
               server: cache
             )

    Agent.update(clock, fn _time -> :timer.hours(24) - 1 end)

    assert {:ok, ^channels} =
             ChannelListCache.fetch(
               connection,
               fn -> flunk("the list should remain cached for the full 24 hours") end,
               server: cache
             )

    Agent.update(clock, fn _time -> :timer.hours(24) end)
    refreshed = [%{channel: "#phoenix", users: 24, topic: "Phoenix"}]

    assert {:ok, ^refreshed} =
             ChannelListCache.fetch(connection, fn -> {:ok, refreshed} end, server: cache)
  end

  test "does not share a server's channel list across users or saved connections" do
    {cache, _clock, _task_supervisor} = start_cache()
    first = connection(1, 10, "IRC.Example.COM.")
    other_user = connection(2, 20, "irc.example.com")
    other_connection = connection(1, 30, "irc.example.com")

    assert {:ok, [:first]} =
             ChannelListCache.fetch(first, fn -> {:ok, [:first]} end, server: cache)

    assert {:ok, [:other_user]} =
             ChannelListCache.fetch(
               other_user,
               fn -> {:ok, [:other_user]} end,
               server: cache
             )

    assert {:ok, [:other_connection]} =
             ChannelListCache.fetch(
               other_connection,
               fn -> {:ok, [:other_connection]} end,
               server: cache
             )
  end

  test "invalidating a connection forces its next request to fetch a fresh list" do
    {cache, _clock, _task_supervisor} = start_cache()
    connection = connection(1, 10, "irc.example.com")

    assert {:ok, [:old]} =
             ChannelListCache.fetch(connection, fn -> {:ok, [:old]} end, server: cache)

    assert :ok = ChannelListCache.invalidate(connection, server: cache)

    assert {:ok, [:fresh]} =
             ChannelListCache.fetch(connection, fn -> {:ok, [:fresh]} end, server: cache)
  end

  test "an invalidated in-flight request cannot overwrite the refreshed list" do
    {cache, _clock, _task_supervisor} = start_cache()
    connection = connection(1, 10, "irc.example.com")
    test_pid = self()

    fetcher =
      start_supervised!(
        {Task,
         fn ->
           result =
             ChannelListCache.fetch(
               connection,
               fn ->
                 send(test_pid, {:old_fetch_started, self()})

                 receive do
                   :finish_old_fetch -> {:ok, [:old]}
                 end
               end,
               server: cache
             )

           send(test_pid, {:old_fetch_finished, result})
         end}
      )

    monitor = Process.monitor(fetcher)
    assert_receive {:old_fetch_started, callback}
    assert :ok = ChannelListCache.invalidate(connection, server: cache)

    assert {:ok, [:fresh]} =
             ChannelListCache.fetch(connection, fn -> {:ok, [:fresh]} end, server: cache)

    send(callback, :finish_old_fetch)
    assert_receive {:old_fetch_finished, {:ok, [:old]}}
    assert_receive {:DOWN, ^monitor, :process, ^fetcher, :normal}

    assert {:ok, [:fresh]} =
             ChannelListCache.fetch(
               connection,
               fn -> flunk("the stale request must not replace the refreshed list") end,
               server: cache
             )
  end

  defp start_cache do
    clock = start_supervised!({Agent, fn -> 0 end})
    task_supervisor = start_supervised!(Task.Supervisor)

    cache =
      start_supervised!(
        {ChannelListCache,
         name: nil, clock: fn -> Agent.get(clock, & &1) end, task_supervisor: task_supervisor}
      )

    {cache, clock, task_supervisor}
  end

  defp connection(user_id, id, host) do
    %ServerConnection{
      id: id,
      user_id: user_id,
      host: host,
      port: 6697,
      use_tls: true,
      nickname: "mira",
      sasl_username: "mira"
    }
  end
end
