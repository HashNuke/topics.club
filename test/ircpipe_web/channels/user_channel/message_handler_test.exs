defmodule IrcpipeWeb.UserChannel.MessageHandlerTest do
  use Ircpipe.DataCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias IrcpipeWeb.UserChannel.MessageHandler

  test "rejects blank channel and direct-message bodies before resolving a buffer" do
    socket = socket()

    for buffer_id <- ["channel:123", "direct:456"] do
      assert {:reply,
              {:error,
               %{
                 reply: "error",
                 reason: "empty_message",
                 client_message_id: "client-1"
               }}, ^socket} =
               MessageHandler.send_message(
                 %{
                   "buffer_id" => buffer_id,
                   "body" => "  ",
                   "client_message_id" => "client-1"
                 },
                 socket
               )
    end
  end

  test "rejects unsupported buffers and preserves the client message id" do
    socket = socket()

    assert {:reply,
            {:error,
             %{
               reply: "error",
               reason: "invalid_buffer",
               client_message_id: "client-2"
             }}, ^socket} =
             MessageHandler.send_message(
               %{
                 "buffer_id" => "server:123",
                 "body" => "hello",
                 "client_message_id" => "client-2"
               },
               socket
             )
  end

  test "sends through an open direct-message thread and returns its persisted message" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user, IrcTestServer.port(server))
    {:ok, thread} = Chat.open_direct_message(user, connection, "akash")
    on_exit(fn -> SessionSupervisor.stop_session(connection) end)
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert {:ok, _client_info} = Session.connection_info(connection)

    socket = socket(user)

    assert {:reply,
            {:ok,
             %{
               reply: "ok",
               client_message_id: "client-dm-success",
               message: %{
                 body: "hello privately",
                 nick: "mira",
                 buffer_id: buffer_id,
                 direct_message_thread_id: thread_id
               }
             }}, ^socket} =
             MessageHandler.send_message(
               %{
                 "buffer_id" => "direct:#{thread.id}",
                 "body" => "hello privately",
                 "client_message_id" => "client-dm-success"
               },
               socket
             )

    assert buffer_id == "direct:#{thread.id}"
    assert thread_id == thread.id
    assert_receive {:irc_server_line, "PRIVMSG akash :hello privately"}, 1_000

    assert Enum.any?(
             Chat.list_buffer_messages(user, buffer_id),
             &(&1.body == "hello privately" and &1.direct_message_thread_id == thread.id)
           )

    assert :ok = Session.quit(connection)
  end

  test "maps a missing direct-message session to not_connected" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user, 6667)
    {:ok, thread} = Chat.open_direct_message(user, connection, "akash")
    socket = socket(user)

    assert {:reply,
            {:error,
             %{
               reply: "error",
               reason: "not_connected",
               client_message_id: "client-dm-offline"
             }}, ^socket} =
             MessageHandler.send_message(
               %{
                 "buffer_id" => "direct:#{thread.id}",
                 "body" => "hello?",
                 "client_message_id" => "client-dm-offline"
               },
               socket
             )
  end

  defp connection_fixture(user, port) do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-#{System.unique_integer([:positive])}",
        "host" => "127.0.0.1",
        "port" => port,
        "use_tls" => false,
        "nickname" => "mira"
      })

    connection
  end

  defp socket(user \\ %{id: 1}) do
    %Phoenix.Socket{assigns: %{current_user: user}}
  end
end
