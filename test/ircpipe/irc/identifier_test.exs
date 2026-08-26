defmodule Ircpipe.Irc.IdentifierTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Identifier

  test "builds case-insensitive IRC keys with the negotiated casemapping" do
    assert Identifier.key("Nick") == "nick"
    assert Identifier.key("[\\]", :rfc1459) == "{|}"
    assert Identifier.key("[\\]", :ascii) == "[\\]"
    assert Identifier.key("~", :rfc1459) == Identifier.key("^", :rfc1459)

    refute Identifier.key("~", :strict_rfc1459) ==
             Identifier.key("^", :strict_rfc1459)
  end

  test "validates nickname syntax and the negotiated NICKLEN" do
    assert Identifier.valid_nick?("pipe|nick", %{"NICKLEN" => "30"})
    assert Identifier.valid_nick?(String.duplicate("a", 30), %{"NICKLEN" => "30"})
    refute Identifier.valid_nick?(String.duplicate("a", 31), %{"NICKLEN" => "30"})
    refute Identifier.valid_nick?("#channel", %{"NICKLEN" => "30"})
    refute Identifier.valid_nick?(nil)

    for isupport <- [%{}, %{"NICKLEN" => "invalid"}, %{"NICKLEN" => "0"}, %{"NICKLEN" => "-1"}] do
      assert Identifier.valid_nick?(String.duplicate("a", 128), isupport)
      refute Identifier.valid_nick?(String.duplicate("a", 129), isupport)
    end
  end
end
