defmodule TopicsClub.Irc.Session.ChannelListVisibilityTest do
  use ExUnit.Case, async: true

  alias Ircxd.Client.Event
  alias Ircxd.Client.Info
  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.ChannelListVisibility

  test "invalidates for self account, operator, and user-mode changes" do
    state = state()

    for name <- [:logged_in, :logged_out, :user_mode, :youre_oper] do
      assert ChannelListVisibility.invalidates_cache?(state, event(name, %{}))
    end

    assert ChannelListVisibility.invalidates_cache?(
             state,
             event(:account, %{nick: "mira", source_self?: true})
           )

    assert ChannelListVisibility.invalidates_cache?(
             state,
             event(:mode, %{target: "mira", target_self?: true})
           )

    for name <- [:join, :part] do
      assert ChannelListVisibility.invalidates_cache?(
               state,
               event(name, %{nick: "mira", source_self?: true})
             )
    end

    assert ChannelListVisibility.invalidates_cache?(
             state,
             event(:kick, %{target_nick: "mira", target_self?: true})
           )
  end

  test "does not invalidate for another user's account or channel modes" do
    state = state()

    refute ChannelListVisibility.invalidates_cache?(
             state,
             event(:account, %{nick: "someone-else", source_self?: false})
           )

    refute ChannelListVisibility.invalidates_cache?(
             state,
             event(:mode, %{target: "#elixir", target_self?: false})
           )

    refute ChannelListVisibility.invalidates_cache?(
             state,
             event(:join, %{nick: "someone-else", source_self?: false})
           )

    refute ChannelListVisibility.invalidates_cache?(
             state,
             event(:kick, %{target_nick: "someone-else", target_self?: false})
           )

    refute ChannelListVisibility.invalidates_cache?(state, event(:privmsg, %{}))
  end

  test "refresh removes the connection's cached list when visibility changes" do
    state = state()
    test_pid = self()

    assert ^state =
             ChannelListVisibility.refresh(
               state,
               event(:logged_in, %{}),
               invalidate: fn connection ->
                 send(test_pid, {:invalidated, connection})
                 :ok
               end
             )

    assert_receive {:invalidated, %ServerConnection{id: 10, user_id: 1}}
  end

  defp state do
    %{
      active_casemapping: :ascii,
      client_info: struct(Info, current_nick: "mira"),
      connection: %ServerConnection{id: 10, user_id: 1, nickname: "mira"},
      isupport_received?: true
    }
  end

  defp event(name, payload), do: Event.from_legacy!({name, payload})
end
