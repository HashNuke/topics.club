defmodule TopicsClub.Irc.SessionLocatorTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.SessionLocator
  alias Ircxd.Client.Info

  test "locates the registered session and reports protocol status" do
    connection = unique_connection()
    session = start_session_stub(connection, info(false))

    assert SessionLocator.whereis(connection) == session
    assert SessionLocator.status(connection) == "connecting"

    send(session, {:set_info, info(true)})
    assert SessionLocator.status(connection) == "connected"
  end

  test "reports disconnected when no session is registered" do
    connection = unique_connection()

    assert SessionLocator.whereis(connection) == nil
    assert SessionLocator.status(connection) == "disconnected"
  end

  test "reports disconnected when a registered session exits during status lookup" do
    connection = unique_connection()
    _session = start_session_stub(connection, :exit_on_connection_info)

    assert SessionLocator.status(connection) == "disconnected"
  end

  defp start_session_stub(connection, info) do
    parent = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _owner} = Registry.register(TopicsClub.Irc.SessionRegistry, key(connection), nil)
           send(parent, {:session_stub_ready, self()})
           session_stub_loop(info)
         end}
      )

    assert_receive {:session_stub_ready, ^pid}
    pid
  end

  defp session_stub_loop(info) do
    receive do
      {:"$gen_call", _from, :connection_info} when info == :exit_on_connection_info ->
        exit(:normal)

      {:"$gen_call", from, :connection_info} ->
        GenServer.reply(from, {:ok, info})
        session_stub_loop(info)

      {:set_info, updated_info} ->
        session_stub_loop(updated_info)
    end
  end

  defp unique_connection do
    id = -System.unique_integer([:positive, :monotonic])
    %ServerConnection{id: id, user_id: id}
  end

  defp info(registered?) do
    %Info{
      status: if(registered?, do: :registered, else: :connected),
      connected?: true,
      registered?: registered?,
      host: "irc.example.test",
      port: 6697,
      tls?: true,
      transport: :ssl,
      desired_nick: "mira",
      current_nick: "mira",
      available_caps: %{},
      active_caps: MapSet.new(),
      isupport: %{},
      casemapping: :rfc1459
    }
  end

  defp key(connection), do: {connection.user_id, connection.id}
end
