defmodule TopicsClub.Chat.PresenceDiffTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.PresenceDiff

  test "canonicalizes every nick-bearing presence diff with the negotiated mapping" do
    assert PresenceDiff.canonicalize(
             %{action: "join", user: %{nick: "[Mira]", role: "op"}},
             :rfc1459
           ) == %{
             action: "join",
             user: %{nick: "[Mira]", nick_key: "{mira}", role: "op"}
           }

    for action <- ["part", "quit", "away", "role"] do
      assert PresenceDiff.canonicalize(
               %{action: action, nick: "[Mira]", marker: :preserved},
               :rfc1459
             ) == %{
               action: action,
               nick: "[Mira]",
               nick_key: "{mira}",
               marker: :preserved
             }
    end

    assert PresenceDiff.canonicalize(
             %{action: "nick", old_nick: "[Mira]", new_nick: "Other"},
             :rfc1459
           ) == %{
             action: "nick",
             old_nick: "[Mira]",
             old_nick_key: "{mira}",
             new_nick: "Other",
             new_nick_key: "other"
           }
  end

  test "supports string-keyed join users and leaves non-nick diffs unchanged" do
    assert PresenceDiff.canonicalize(
             %{action: "join", user: %{"nick" => "Mira", "role" => "user"}},
             :ascii
           ) == %{
             action: "join",
             user: %{"nick" => "Mira", "role" => "user", nick_key: "mira"}
           }

    diff = %{action: "opaque", payload: :unchanged}
    assert PresenceDiff.canonicalize(diff, :rfc1459) == diff
  end
end
