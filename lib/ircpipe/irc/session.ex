defmodule Ircpipe.Irc.Session do
  use GenServer

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Chat.ServerConnection

  def child_spec(%ServerConnection{} = connection) do
    %{
      id: {__MODULE__, connection.user_id, connection.id},
      start: {__MODULE__, :start_link, [connection]},
      restart: :transient
    }
  end

  def start_link(%ServerConnection{} = connection) do
    GenServer.start_link(__MODULE__, connection, name: via(connection))
  end

  def join(%ServerConnection{} = connection, channel) do
    GenServer.call(via(connection), {:join, Chat.normalize_channel(channel)})
  end

  def say(%ServerConnection{} = connection, channel, body) do
    GenServer.call(via(connection), {:say, Chat.normalize_channel(channel), body})
  end

  def part(%ServerConnection{} = connection, channel, reason \\ "") do
    GenServer.call(via(connection), {:part, Chat.normalize_channel(channel), reason})
  end

  def quit(%ServerConnection{} = connection, reason \\ "leaving") do
    GenServer.call(via(connection), {:quit, reason})
  end

  def via(%ServerConnection{user_id: user_id, id: id}) do
    {:via, Registry, {Ircpipe.Irc.SessionRegistry, {user_id, id}}}
  end

  @impl true
  def init(%ServerConnection{} = connection) do
    send(self(), :connect)

    {:ok,
     %{
       connection: connection,
       client: nil,
       registered?: false,
       pending_joins: persisted_channels(connection)
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    connection = state.connection
    record_server_line(connection, "Connecting to #{connection.host}:#{connection.port}.")
    update_status(connection, "connecting")

    opts = [
      host: connection.host,
      port: connection.port,
      tls: connection.use_tls,
      nick: connection.nickname,
      username: connection.username || connection.nickname,
      realname: connection.realname || connection.nickname,
      caps: ["server-time", "echo-message", "multi-prefix", "userhost-in-names"],
      notify: self()
    ]

    opts =
      if present?(connection.sasl_username) and present?(connection.sasl_password) do
        Keyword.put(opts, :sasl, {:plain, connection.sasl_username, connection.sasl_password})
      else
        opts
      end

    case Ircxd.start_link(opts) do
      {:ok, client} ->
        {:noreply, %{state | client: client}}

      {:error, reason} ->
        Logger.warning(
          "IRC connection failed for #{connection.host}:#{connection.port}: #{inspect(reason)}"
        )

        record_server_line(
          connection,
          "Connection to #{connection.host}:#{connection.port} failed: #{inspect(reason)}.",
          "error"
        )

        update_status(connection, "errored")
        {:stop, reason, state}
    end
  end

  def handle_info({:ircxd, :registered}, state) do
    {:ok, updated} = update_status(state.connection, "connected")
    record_server_line(updated, "Connected to #{updated.host}.")
    Enum.each(state.pending_joins, &Ircxd.Client.join(state.client, &1))
    {:noreply, %{state | connection: updated, registered?: true}}
  end

  def handle_info({:ircxd, {:connect_error, reason}}, state) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")

    record_server_line(
      state.connection,
      "Connection error for #{state.connection.host}: #{inspect(reason)}.",
      "error"
    )

    update_status(state.connection, "errored")
    {:noreply, state}
  end

  def handle_info({:ircxd, :disconnected}, state) do
    record_server_line(state.connection, "Disconnected from #{state.connection.host}.")
    update_status(state.connection, "disconnected")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:reconnecting, _payload}}, state) do
    record_server_line(
      state.connection,
      "Reconnecting to #{state.connection.host}:#{state.connection.port}."
    )

    update_status(state.connection, "connecting")
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:privmsg, %{target: "#" <> _ = channel, nick: nick, body: body}}},
        state
      ) do
    Chat.record_inbound_message(state.connection, channel, nick, body)
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:notice, %{target: "#" <> _ = channel, nick: nick, body: body}}},
        state
      ) do
    Chat.record_inbound_message(state.connection, channel, nick, body, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:names, %{channel: channel, names: names}}}, state) do
    Chat.broadcast_presence_sync(state.connection, channel, names)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:join, %{channel: channel, nick: nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, channel, %{
      action: "join",
      user: %{nick: nick, role: "user", status: "online"}
    })

    record_channel_line(state.connection, channel, "join", nick, "#{nick} joined #{channel}.")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:part, %{channel: channel, nick: nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, channel, %{action: "part", nick: nick})
    record_channel_line(state.connection, channel, "part", nick, "#{nick} left #{channel}.")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:quit, %{nick: nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, nil, %{action: "quit", nick: nick})
    record_channel_line_all(state.connection, "quit", nick, fn _membership -> "#{nick} quit." end)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:nick, %{old_nick: old_nick, new_nick: new_nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, nil, %{
      action: "nick",
      old_nick: old_nick,
      new_nick: new_nick
    })

    record_channel_line_all(state.connection, "nick", new_nick, fn _membership ->
      "#{old_nick} is now #{new_nick}."
    end)

    {:noreply, state}
  end

  def handle_info({:ircxd, _event}, state), do: {:noreply, state}

  @impl true
  def handle_call({:join, channel}, _from, state) do
    state = %{state | pending_joins: MapSet.put(state.pending_joins, channel)}

    result =
      case state.client do
        nil -> :ok
        client when state.registered? -> Ircxd.Client.join(client, channel)
        _client -> :ok
      end

    {:reply, normalize_result(result), state}
  end

  def handle_call({:say, channel, body}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.privmsg(client, channel, body) do
      Chat.record_inbound_message(state.connection, channel, state.connection.nickname, body)
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:part, channel, reason}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.part(client, channel, reason) do
      {:reply, :ok, %{state | pending_joins: MapSet.delete(state.pending_joins, channel)}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:quit, reason}, _from, state) do
    result =
      case state.client do
        nil -> :ok
        client -> Ircxd.Client.quit(client, reason)
      end

    record_server_line(state.connection, "Disconnected from #{state.connection.host}.")
    {:stop, :normal, normalize_result(result), state}
  end

  @impl true
  def terminate(_reason, %{connection: connection}) do
    update_status(connection, "disconnected")
    :ok
  end

  defp update_status(connection, status) do
    Chat.update_connection_status(connection, status)
  rescue
    Ecto.StaleEntryError -> {:ok, connection}
    DBConnection.OwnershipError -> {:ok, connection}
  catch
    :exit, _reason -> {:ok, connection}
  end

  defp record_server_line(connection, body, kind \\ "system") do
    Chat.record_server_message(connection, body, kind)
  rescue
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line(connection, channel, kind, nick, body) do
    Chat.record_channel_system_message(connection, channel, kind, nick, body)
  rescue
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line_all(connection, kind, nick, body_fun) do
    Chat.record_channel_system_message_all(connection, kind, nick, body_fun)
  rescue
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error

  defp persisted_channels(%ServerConnection{channel_memberships: memberships})
       when is_list(memberships) do
    memberships
    |> Enum.map(& &1.channel)
    |> MapSet.new()
  end

  defp persisted_channels(_connection), do: MapSet.new()

  defp present?(value), do: is_binary(value) and value != ""
end
