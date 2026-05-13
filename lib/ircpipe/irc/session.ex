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
       pending_joins: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    connection = state.connection
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

        update_status(connection, "errored")
        {:stop, reason, state}
    end
  end

  def handle_info({:ircxd, :registered}, state) do
    {:ok, updated} = update_status(state.connection, "connected")
    Enum.each(state.pending_joins, &Ircxd.Client.join(state.client, &1))
    {:noreply, %{state | connection: updated, registered?: true}}
  end

  def handle_info({:ircxd, {:connect_error, reason}}, state) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")
    update_status(state.connection, "errored")
    {:noreply, state}
  end

  def handle_info({:ircxd, :disconnected}, state) do
    update_status(state.connection, "disconnected")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:reconnecting, _payload}}, state) do
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

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error

  defp present?(value), do: is_binary(value) and value != ""
end
