defmodule TopicsClub.Irc.ChannelListCacheTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.ChannelListCache

  test "shares parsed channel lists by server identity until the one-hour expiry" do
    clock = start_supervised!({Agent, fn -> 0 end})
    task_supervisor = start_supervised!(Task.Supervisor)

    cache =
      start_supervised!(
        {ChannelListCache,
         name: nil, clock: fn -> Agent.get(clock, & &1) end, task_supervisor: task_supervisor}
      )

    first_connection = connection(1, 10, "IRC.Example.COM.")
    other_user_connection = connection(2, 20, "irc.example.com")
    test_pid = self()
    channels = [%{channel: "#elixir", users: 42, topic: "Elixir"}]

    assert {:ok, ^channels} =
             ChannelListCache.fetch(
               first_connection,
               fn ->
                 send(test_pid, :irc_list_requested)
                 {:ok, channels}
               end,
               server: cache
             )

    assert_receive :irc_list_requested

    assert {:ok, ^channels} =
             ChannelListCache.fetch(
               other_user_connection,
               fn -> flunk("the second user should receive the shared cached list") end,
               server: cache
             )

    Agent.update(clock, fn _time -> :timer.hours(1) end)
    refreshed_channels = [%{channel: "#phoenix", users: 24, topic: "Phoenix"}]

    assert {:ok, ^refreshed_channels} =
             ChannelListCache.fetch(
               other_user_connection,
               fn -> {:ok, refreshed_channels} end,
               server: cache
             )
  end

  defp connection(user_id, id, host) do
    %ServerConnection{
      id: id,
      user_id: user_id,
      host: host,
      port: 6697,
      use_tls: true
    }
  end
end
