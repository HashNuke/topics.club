defmodule Ircpipe.Irc.Session.ChannelListEventsTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.{ChannelListEvents, ChannelListRequest}

  test "resets, accumulates, and completes a channel list request" do
    reply_ref = make_ref()

    request =
      {self(), reply_ref}
      |> ChannelListRequest.new()
      |> ChannelListRequest.add(%{channel: "#stale", visible: "1"})

    assert {:handled, state} =
             ChannelListEvents.handle_irc(
               %{channel_list_request: request},
               {:list_start, %{}}
             )

    assert state.channel_list_request.entries == %{}

    assert {:handled, state} =
             ChannelListEvents.handle_irc(
               state,
               {:list_entry, %{channel: "#elixir", visible: "42"}}
             )

    assert {:handled, state} = ChannelListEvents.handle_irc(state, {:list_end, %{}})

    assert state.channel_list_request == nil
    assert_receive {^reply_ref, {:ok, [%{channel: "#elixir", users: 42, topic: ""}]}}
  end

  test "expires only the current request reference" do
    reply_ref = make_ref()
    request = ChannelListRequest.new({self(), reply_ref})
    state = %{channel_list_request: request}

    assert ChannelListEvents.timeout(state, make_ref()) == state

    expired = ChannelListEvents.timeout(state, request.ref)
    assert expired.channel_list_request == nil
    assert_receive {^reply_ref, {:error, :list_timeout}}
  end

  test "leaves unsolicited and malformed list events for the fallback handler" do
    state = %{channel_list_request: nil}

    assert ChannelListEvents.handle_irc(state, {:list_start, %{}}) == :unhandled
    assert ChannelListEvents.handle_irc(state, {:list_entry, %{visible: "2"}}) == :unhandled
    assert ChannelListEvents.handle_irc(state, {:list_end, %{}}) == :unhandled
  end

  test "leaves a malformed list entry unhandled while preserving an active request" do
    request = ChannelListRequest.new({self(), make_ref()})
    state = %{channel_list_request: request}

    assert ChannelListEvents.handle_irc(state, {:list_entry, %{visible: "2"}}) == :unhandled
    assert state.channel_list_request == request

    Process.cancel_timer(request.timer)
  end
end
