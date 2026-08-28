defmodule Ircpipe.Chat.PeerIdentityTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Chat.{DirectMessageThread, PeerIdentity}

  test "derives normalized account and stable hostmask identities from metadata" do
    assert PeerIdentity.details(%{
             "hostmask" => "Nick!User@Example.COM",
             account: "  Alice  "
           }) == %{
             account: "Alice",
             hostmask: "Nick!User@Example.COM",
             primary_key: "account:alice",
             keys: ["account:alice", "hostmask:user@example.com"]
           }
  end

  test "ignores missing and wildcard accounts and falls back to the hostmask" do
    assert PeerIdentity.details(%{"account" => "*", "hostmask" => "service.example"}) == %{
             account: nil,
             hostmask: "service.example",
             primary_key: "hostmask:service.example",
             keys: ["hostmask:service.example"]
           }

    assert PeerIdentity.details(%{account: " ", hostmask: " "}) == %{
             account: nil,
             hostmask: nil,
             primary_key: nil,
             keys: []
           }
  end

  test "builds thread keys with a persisted primary identity first and without duplicates" do
    thread = %DirectMessageThread{
      account: "Alice",
      hostmask: "OldNick!User@Example.COM",
      identity_key: "account:alice"
    }

    assert PeerIdentity.thread_keys(thread) == [
             "account:alice",
             "hostmask:user@example.com"
           ]
  end

  test "retains a historical primary identity alongside current identity fields" do
    thread = %DirectMessageThread{
      account: "Alice",
      hostmask: "Nick!new@example.com",
      identity_key: "account:former"
    }

    assert PeerIdentity.thread_keys(thread) == [
             "account:former",
             "account:alice",
             "hostmask:new@example.com"
           ]
  end
end
