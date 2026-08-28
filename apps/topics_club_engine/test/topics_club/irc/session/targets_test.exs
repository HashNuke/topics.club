defmodule TopicsClub.Irc.Session.TargetsTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.Targets
  alias Ircxd.Client.Info

  test "classifies channel targets using negotiated ISUPPORT" do
    state = negotiated_state(%{"CHANTYPES" => "~", "STATUSMSG" => "@+"}, :ascii)

    assert Targets.channel(state, "~elixir") == "~elixir"
    assert Targets.channel(state, "@~elixir") == "~elixir"
    assert Targets.channel?(state, "+~elixir")
    refute Targets.channel?(state, "#elixir")
    refute Targets.channel?(state, "nick")
  end

  test "uses standard channel prefixes before ISUPPORT arrives" do
    state = %{connection: %ServerConnection{}, isupport_received?: false}

    for channel <- ["#elixir", "&staff", "+modeless", "!safe"] do
      assert Targets.channel(state, channel) == channel
      assert Targets.channel?(state, channel)
    end

    refute Targets.channel?(state, "nick")
    refute Targets.channel?(state, nil)
  end

  test "normalizes identifiers and status-prefixed channel keys with negotiated casemapping" do
    state =
      %{"CHANTYPES" => "#", "STATUSMSG" => "@"}
      |> negotiated_state(:rfc1459)
      |> Map.put(:active_casemapping, :rfc1459)

    assert Targets.normalize(state, "[Nick]") == "{nick}"
    assert Targets.key(state, "@#[Room]") == "\#{room}"
  end

  test "prefers the active mapping and otherwise uses the stored connection mapping" do
    assert Targets.casemapping(%{active_casemapping: :strict_rfc1459}) == :strict_rfc1459

    for {stored, expected} <- [
          {"rfc1459", :rfc1459},
          {"strict_rfc1459", :strict_rfc1459},
          {"ascii", :ascii},
          {nil, :ascii}
        ] do
      state = %{active_casemapping: nil, connection: %ServerConnection{casemapping: stored}}
      assert Targets.casemapping(state) == expected
    end
  end

  test "exposes negotiated ISUPPORT and defaults to an empty map" do
    state = negotiated_state(%{"CHANTYPES" => "~"}, :ascii)

    assert Targets.isupport(state) == %{"CHANTYPES" => "~"}
    assert Targets.isupport(%{}) == %{}
  end

  defp negotiated_state(isupport, casemapping) do
    %{
      active_casemapping: nil,
      connection: %ServerConnection{},
      client_info: struct(Info, isupport: isupport, casemapping: casemapping),
      isupport_received?: true
    }
  end
end
