defmodule TopicsClub.Irc.WirekeeperTransportTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Irc.WirekeeperTransport
  alias TopicsClub.Irc.Session
  alias TopicsClub.Irc.Session.EventDispatcher
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Wirekeeper

  for mode <- [:direct, :wirekeeper] do
    @mode mode

    test "the IRC scenario works in #{@mode} mode" do
      server = start_supervised!({IrcTestServer, self()})
      {client, context} = start_client(@mode, server)

      assert_event(client, context, fn event -> event == :registered end)
      await_drained(context)

      assert :ok = IrcTestServer.broadcast(server, "#elixir", "friend", "hello inbound")

      assert_event(client, context, fn
        {:privmsg, %{target: "#elixir", nick: "friend", body: "hello inbound"}} -> true
        _event -> false
      end)

      assert :ok = Ircxd.Client.privmsg(client, "#elixir", "hello outbound")
      assert_server_line("PRIVMSG #elixir :hello outbound", context)
    end
  end

  test "late Wirekeeper signals are harmless while a Session has no IRC client" do
    state = %{client: nil, retry_attempt: 1}

    for event <- [
          {:data, %{generation: "old", sequence: 1, payload: "PING :late\r\n"}},
          {:upstream_closed, %{generation: "old", reason: :closed}},
          {:overflow, %{generation: "old"}}
        ] do
      assert {:noreply, ^state} = Session.handle_info({:topics_club_wirekeeper, event}, state)
    end
  end

  test "transport health is optional in direct mode and checks the Wirekeeper API in retained mode" do
    previous = Application.get_env(:topics_club_engine, :irc_transport)

    on_exit(fn -> restore_transport(previous) end)

    Application.put_env(:topics_club_engine, :irc_transport, :direct)
    assert :ok = WirekeeperTransport.health()

    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, node()})
    assert :ok = WirekeeperTransport.health()

    Application.put_env(
      :topics_club_engine,
      :irc_transport,
      {:wirekeeper, :missing_wirekeeper@localhost}
    )

    assert {:error, :unavailable} = WirekeeperTransport.health()
  end

  test "a failed detach stops the Session instead of retrying with uncertain ownership" do
    previous = Application.get_env(:topics_club_engine, :irc_transport)

    on_exit(fn -> restore_transport(previous) end)

    Application.put_env(
      :topics_club_engine,
      :irc_transport,
      {:wirekeeper, :missing_wirekeeper@localhost}
    )

    client = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor_ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^client, :killed}

    state = %{
      client: client,
      client_monitor: monitor_ref,
      connection: %{id: 123}
    }

    assert {:stop, {:wirekeeper_detach_failed, :unavailable}, stopped} =
             Session.handle_info({:DOWN, monitor_ref, :process, client, :killed}, state)

    assert stopped.client == nil
    assert stopped.client_monitor == nil
  end

  test "a monitored Wirekeeper node loss closes only its current transport handle" do
    handle =
      {WirekeeperTransport, :wirekeeper@localhost, "connection-1", "generation-1", self(), self()}

    assert {:closed, {:wirekeeper_node_down, :wirekeeper@localhost}} =
             WirekeeperTransport.handle_info({:nodedown, :wirekeeper@localhost}, handle)

    assert {:closed, {:wirekeeper_node_down, :wirekeeper@localhost}} =
             WirekeeperTransport.handle_info(
               {:nodedown, :wirekeeper@localhost, [nodedown_reason: :connection_closed]},
               handle
             )

    assert :unknown =
             WirekeeperTransport.handle_info({:nodedown, :another_node@localhost}, handle)

    assert :ok =
             WirekeeperTransport.close(
               handle,
               {:wirekeeper_node_down, :wirekeeper@localhost}
             )
  end

  test "an unavailable remote Wirekeeper does not leave a stale node-down monitor event" do
    target_node = :missing_wirekeeper_monitor@localhost

    opts = [
      key: "monitored-connection",
      node: target_node,
      consumer: self(),
      transport: {:tcp, host: "127.0.0.1", port: 6667}
    ]

    assert {:error, :unavailable} = WirekeeperTransport.connect(self(), %{}, opts)
    refute_receive {:nodedown, ^target_node}
  end

  test "an uncertain keyed write closes the Ircxd transport without an ordinary fallback" do
    handle =
      {WirekeeperTransport, node(), "missing-send-once", "generation-1", self(), self()}

    assert {:error, {:wirekeeper_send_once, :not_found}} =
             WirekeeperTransport.send_data_once(
               handle,
               ["attempt-1"],
               "JOIN #elixir\r\n"
             )

    assert_receive {:ircxd_transport, ^handle,
                    {:closed, {:wirekeeper_send_once_failed, :not_found}}}
  end

  test "the Session records a verified Wirekeeper node loss for safe retry fencing" do
    state = %{wirekeeper_node_down?: false}

    assert %{wirekeeper_node_down?: true} =
             EventDispatcher.dispatch(
               state,
               {:disconnect,
                %{
                  reason: {:wirekeeper_node_down, :wirekeeper@localhost},
                  intentional?: false,
                  reconnecting?: false
                }}
             )
  end

  defp start_client(mode, server, key \\ nil) do
    key = key || "engine-transport-#{System.unique_integer([:positive, :monotonic])}"

    opts = [
      host: "127.0.0.1",
      port: IrcTestServer.port(server),
      nick: "keeper",
      notify: self(),
      reconnect: false
    ]

    {opts, context} =
      case mode do
        :direct ->
          {opts, %{mode: :direct}}

        :wirekeeper ->
          adapter_opts = [
            key: key,
            node: node(),
            consumer: self(),
            transport: {:tcp, host: "127.0.0.1", port: IrcTestServer.port(server)}
          ]

          {Keyword.put(opts, :transport_adapter, {WirekeeperTransport, adapter_opts}),
           %{mode: :wirekeeper, key: key}}
      end

    assert {:ok, client} = Ircxd.Client.start_link(opts)

    if mode == :wirekeeper do
      on_exit(fn -> close_wirekeeper(key) end)
    end

    {client, context}
  end

  defp assert_event(client, context, predicate) do
    receive do
      {:ircxd, event} ->
        if predicate.(event), do: event, else: assert_event(client, context, predicate)

      {:topics_club_wirekeeper, {:data, payload}} ->
        :ok = WirekeeperTransport.deliver(client, payload)
        assert_event(client, context, predicate)

      {:topics_club_wirekeeper_transport, {:accepted, accepted}} ->
        :ok = WirekeeperTransport.acknowledge(accepted)
        assert_event(client, context, predicate)

      {:topics_club_wirekeeper, {:upstream_closed, payload}} ->
        :ok = WirekeeperTransport.upstream_closed(client, payload)
        assert_event(client, context, predicate)

      {:topics_club_wirekeeper, {:overflow, payload}} ->
        :ok = WirekeeperTransport.overflowed(client, payload)
        assert_event(client, context, predicate)

      _other ->
        assert_event(client, context, predicate)
    after
      2_000 -> flunk("expected IRC event in #{context.mode} mode")
    end
  end

  defp assert_server_line(expected, context) do
    receive do
      {:irc_server_line, ^expected} ->
        :ok

      {:topics_club_wirekeeper_transport, {:accepted, accepted}} ->
        :ok = WirekeeperTransport.acknowledge(accepted)
        assert_server_line(expected, context)

      _other ->
        assert_server_line(expected, context)
    after
      2_000 -> flunk("expected #{inspect(expected)} in #{context.mode} mode")
    end
  end

  defp await_drained(context), do: await_drained(context, 2_000)

  defp await_drained(%{mode: :direct}, _attempts), do: :ok

  defp await_drained(%{mode: :wirekeeper, key: key} = context, attempts)
       when attempts > 0 do
    receive do
      {:topics_club_wirekeeper_transport, {:accepted, accepted}} ->
        :ok = WirekeeperTransport.acknowledge(accepted)
        await_drained(context, attempts - 1)
    after
      10 ->
        case Wirekeeper.info(key) do
          {:ok, %{buffered_records: 0}} -> :ok
          {:ok, _info} -> await_drained(context, attempts - 1)
        end
    end
  end

  defp await_drained(context, 0), do: flunk("Wirekeeper did not drain in #{context.mode} mode")

  defp close_wirekeeper(key) do
    case Wirekeeper.info(key) do
      {:ok, %{generation: generation}} -> Wirekeeper.close(key, generation)
      {:error, _reason} -> :ok
    end
  end

  defp restore_transport(nil), do: Application.delete_env(:topics_club_engine, :irc_transport)

  defp restore_transport(transport),
    do: Application.put_env(:topics_club_engine, :irc_transport, transport)
end
