defmodule TopicsClub.Irc.Session.ChannelListRequestTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.ChannelListRequest

  test "collects entries and replies with visible-user ordering" do
    reply_ref = make_ref()
    request = ChannelListRequest.new({self(), reply_ref})

    request =
      request
      |> ChannelListRequest.add(%{channel: "#quiet", visible: "4", topic: nil})
      |> ChannelListRequest.add(%{channel: "#Elixir", visible: 42, topic: "Beam"})
      |> ChannelListRequest.add(%{channel: "#broken", visible: "many", topic: "Unknown"})

    assert ChannelListRequest.complete(request) == nil

    assert_receive {^reply_ref,
                    {:ok,
                     [
                       %{channel: "#Elixir", users: 42, topic: "Beam"},
                       %{channel: "#quiet", users: 4, topic: ""},
                       %{channel: "#broken", users: 0, topic: "Unknown"}
                     ]}}
  end

  test "restarts collection and sends a timeout reply" do
    reply_ref = make_ref()

    request =
      {self(), reply_ref}
      |> ChannelListRequest.new()
      |> ChannelListRequest.add(%{channel: "#old", visible: "1"})
      |> ChannelListRequest.reset()

    assert request.entries == %{}
    assert ChannelListRequest.expire(request) == nil
    assert_receive {^reply_ref, {:error, :list_timeout}}
  end
end
