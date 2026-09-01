defmodule TopicsClub.IrcTestServerTest do
  use ExUnit.Case, async: true

  alias TopicsClub.IrcTestServer

  test "an unrelated HTTP probe does not consume the IRC connection slot" do
    server = start_supervised!({IrcTestServer, self()})
    server_ref = Process.monitor(server)
    port = IrcTestServer.port(server)

    {:ok, probe} =
      :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

    :ok = :gen_tcp.send(probe, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    :ok = :gen_tcp.close(probe)

    refute_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 300

    {:ok, irc_socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])

    on_exit(fn -> :gen_tcp.close(irc_socket) end)

    :ok = :gen_tcp.send(irc_socket, "NICK topics_club\r\n")
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
  end
end
