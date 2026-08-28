defmodule TopicsClub.Irc.CommandResultTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.CommandResult
  alias Ircxd.Client.Event

  test "keeps standard-reply severity and description readable and structured" do
    event =
      Event.from_legacy!(
        {:standard_reply,
         %{
           type: :fail,
           command: "WHOIS",
           code: "INVALID_TARGET",
           context: ["private-context"],
           description: "That nickname is unavailable."
         }}
      )

    result = CommandResult.format(event)

    assert result.body =~ "type=fail"
    assert result.body =~ "description=That nickname is unavailable."
    assert result.metadata.irc_payload["type"] == "fail"
    assert result.metadata.irc_payload["description"] == "That nickname is unavailable."
    refute result.body =~ "private-context"
  end
end
