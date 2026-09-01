defmodule TopicsClub.Irc.Session.ClientOptionsTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.ClientOptions

  setup do
    previous = Application.get_env(:topics_club_engine, :irc_transport)
    previous_binding = Application.get_env(:topics_club_engine, :wirekeeper_resume_binding)
    Application.put_env(:topics_club_engine, :irc_transport, :direct)
    Application.delete_env(:topics_club_engine, :wirekeeper_resume_binding)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:topics_club_engine, :irc_transport)
      else
        Application.put_env(:topics_club_engine, :irc_transport, previous)
      end

      if is_nil(previous_binding) do
        Application.delete_env(:topics_club_engine, :wirekeeper_resume_binding)
      else
        Application.put_env(
          :topics_club_engine,
          :wirekeeper_resume_binding,
          previous_binding
        )
      end
    end)
  end

  test "builds envelope client options with identity fallbacks and required capabilities" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira"
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:host] == "irc.example.test"
    assert opts[:port] == 6697
    assert opts[:tls]
    assert opts[:nick] == "mira"
    assert opts[:username] == "mira"
    assert opts[:realname] == "mira"
    assert opts[:reconnect] == false
    assert opts[:events] == :envelope
    assert opts[:additional_error_numerics] == ["479", "480"]
    assert opts[:notify] == self()

    assert opts[:caps] == [
             "server-time",
             "echo-message",
             "multi-prefix",
             "userhost-in-names",
             "message-tags",
             "batch",
             "labeled-response"
           ]

    refute Keyword.has_key?(opts, :password)
    refute Keyword.has_key?(opts, :sasl)
    refute Keyword.has_key?(opts, :transport_adapter)
  end

  test "opts into the Wirekeeper transport with a stable connection key" do
    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, :wirekeeper@test})

    connection = %ServerConnection{
      id: 42,
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira"
    }

    opts = ClientOptions.build(connection, self())

    assert {TopicsClub.Irc.WirekeeperTransport, adapter_opts} = opts[:transport_adapter]
    assert adapter_opts[:key] == 42
    assert adapter_opts[:node] == :wirekeeper@test
    assert adapter_opts[:consumer] == self()
    assert adapter_opts[:transport] == {:tls, host: "irc.example.test", port: 6697}
    assert opts[:resume_binding] == "server-connection/42/transport-revision/1"

    Application.put_env(
      :topics_club_engine,
      :wirekeeper_resume_binding,
      "deployment-generation-7"
    )

    revised_opts = ClientOptions.build(%{connection | transport_revision: 3}, self())

    assert revised_opts[:resume_binding] ==
             "server-connection/42/transport-revision/3/deployment/deployment-generation-7"
  end

  test "adds server password and only complete SASL credentials" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6667,
      use_tls: false,
      nickname: "mira",
      username: "ident",
      realname: "Mira Example",
      server_password: "server-secret",
      sasl_username: "account",
      sasl_password: "account-secret"
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:username] == "ident"
    assert opts[:realname] == "Mira Example"
    assert opts[:password] == "server-secret"
    assert opts[:sasl] == {:plain, "account", "account-secret"}

    incomplete = ClientOptions.build(%{connection | sasl_password: ""}, self())
    refute Keyword.has_key?(incomplete, :sasl)

    incomplete = ClientOptions.build(%{connection | sasl_username: ""}, self())
    refute Keyword.has_key?(incomplete, :sasl)
  end

  test "preserves blank identity fields while omitting a blank server password" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira",
      username: "",
      realname: "",
      server_password: ""
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:username] == ""
    assert opts[:realname] == ""
    refute Keyword.has_key?(opts, :password)
  end
end
