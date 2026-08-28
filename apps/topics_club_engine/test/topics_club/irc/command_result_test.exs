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

  test "formats WHOIS replies as two concise sentences" do
    events =
      Enum.map(
        [
          {:whois_user,
           %{nick: "dev3dev", username: "~dev", host: "example.test", realname: "dev"}},
          {:whois_channels, %{nick: "dev3dev", channels: ["@#elixir", "#irc"]}},
          {:whois_server,
           %{nick: "dev3dev", server: "iridium.libera.chat", info: "Frankfurt, DE"}},
          {:whois_secure,
           %{
             nick: "dev3dev",
             text: "is using a secure connection [TLSv1.3, TLS_AES_256_GCM_SHA384]"
           }},
          {:whois_idle, %{nick: "dev3dev", idle_seconds: 12, signon: 0}}
        ],
        &Event.from_legacy!/1
      )

    result = CommandResult.format_whois(events)

    assert result.body ==
             "dev3dev (~dev@example.test) — dev. Channels: #elixir (operator), #irc; " <>
               "Server: iridium.libera.chat (Frankfurt, DE); Secure: TLSv1.3, " <>
               "TLS_AES_256_GCM_SHA384; Idle: 12 seconds (connected since " <>
               "1970-01-01 00:00 UTC)."

    assert result.metadata.irc_event == "whois_summary"
    assert length(result.metadata.irc_payload["replies"]) == 5
  end

  test "does not render absent generic fields as empty values" do
    result =
      Event.from_legacy!({:who_reply, %{nick: "dev3dev"}})
      |> CommandResult.format()

    assert result.body == "Who reply — nick=dev3dev"
    refute result.body =~ "account="
  end
end
