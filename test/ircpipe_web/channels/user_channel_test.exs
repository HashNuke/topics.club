defmodule IrcpipeWeb.UserChannelTest do
  use IrcpipeWeb.ChannelCase, async: true

  alias Ircpipe.AccountsFixtures
  alias IrcpipeWeb.UserChannel
  alias IrcpipeWeb.UserSocket

  test "suggests slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user_socket:#{user.id}", %{current_user: user})
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    ref = push(socket, "command:suggest", %{"input" => "/jo"})

    assert_reply ref, :ok, %{commands: [%{name: "/join"}]}
  end

  test "parses supported slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user_socket:#{user.id}", %{current_user: user})
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    ref = push(socket, "command:parse", %{"input" => "/msg NickServ help"})

    assert_reply ref, :ok, %{command: %{name: "msg", args: ["NickServ", "help"]}}
  end

  test "rejects unknown slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user_socket:#{user.id}", %{current_user: user})
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    ref = push(socket, "command:parse", %{"input" => "/wat"})

    assert_reply ref, :error, %{reason: "unknown_command", command: "wat"}
  end
end
