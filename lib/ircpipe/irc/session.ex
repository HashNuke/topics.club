defmodule Ircpipe.Irc.Session do
  use GenServer

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Chat.ServerConnection

  @tcp_opts [:binary, packet: :line, active: true]

  def start_link(%ServerConnection{} = connection) do
    GenServer.start_link(__MODULE__, connection, name: via(connection))
  end

  def join(%ServerConnection{} = connection, channel) do
    GenServer.call(via(connection), {:join, Chat.normalize_channel(channel)})
  end

  def say(%ServerConnection{} = connection, channel, body) do
    GenServer.call(via(connection), {:say, Chat.normalize_channel(channel), body})
  end

  def via(%ServerConnection{user_id: user_id, id: id}) do
    {:via, Registry, {Ircpipe.Irc.SessionRegistry, {user_id, id}}}
  end

  @impl true
  def init(%ServerConnection{} = connection) do
    send(self(), :connect)
    {:ok, %{connection: connection, socket: nil, transport: nil, buffer: ""}}
  end

  @impl true
  def handle_info(:connect, state) do
    connection = state.connection
    Chat.update_connection_status(connection, "connecting")

    case connect(connection) do
      {:ok, transport, socket} ->
        register(connection, transport, socket)
        {:ok, updated} = Chat.update_connection_status(connection, "connected")
        {:noreply, %{state | connection: updated, socket: socket, transport: transport}}

      {:error, reason} ->
        Logger.warning(
          "IRC connection failed for #{connection.host}:#{connection.port}: #{inspect(reason)}"
        )

        Chat.update_connection_status(connection, "errored")
        {:stop, reason, state}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state), do: handle_line(line, state)
  def handle_info({:ssl, socket, line}, %{socket: socket} = state), do: handle_line(line, state)

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :tcp_closed, state}
  def handle_info({:ssl_closed, _socket}, state), do: {:stop, :ssl_closed, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, reason, state}
  def handle_info({:ssl_error, _socket, reason}, state), do: {:stop, reason, state}

  @impl true
  def handle_call({:join, channel}, _from, state) do
    with :ok <- send_line(state, "JOIN #{channel}") do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:say, channel, body}, _from, state) do
    with :ok <- send_line(state, "PRIVMSG #{channel} :#{body}") do
      Chat.record_inbound_message(state.connection, channel, state.connection.nickname, body)
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def terminate(_reason, %{connection: connection}) do
    Chat.update_connection_status(connection, "disconnected")
    :ok
  end

  defp connect(%ServerConnection{use_tls: true} = connection) do
    with {:ok, socket} <-
           :ssl.connect(String.to_charlist(connection.host), connection.port, @tcp_opts, 10_000) do
      {:ok, :ssl, socket}
    end
  end

  defp connect(%ServerConnection{} = connection) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(connection.host),
             connection.port,
             @tcp_opts,
             10_000
           ) do
      {:ok, :gen_tcp, socket}
    end
  end

  defp register(connection, transport, socket) do
    if present?(connection.server_password),
      do: send_line(transport, socket, "PASS #{connection.server_password}")

    username = connection.username || connection.nickname
    realname = connection.realname || connection.nickname

    send_line(transport, socket, "NICK #{connection.nickname}")
    send_line(transport, socket, "USER #{username} 0 * :#{realname}")
  end

  defp handle_line(line, state) do
    line = String.trim(line)

    cond do
      String.starts_with?(line, "PING ") ->
        server = String.replace_prefix(line, "PING ", "")
        send_line(state, "PONG #{server}")
        {:noreply, state}

      true ->
        parse_privmsg(line, state.connection)
        {:noreply, state}
    end
  end

  defp parse_privmsg(":" <> rest, connection) do
    with [prefix, command_and_args] <- String.split(rest, " ", parts: 2),
         true <- String.starts_with?(command_and_args, "PRIVMSG "),
         ["PRIVMSG", channel, ":" <> body] <- String.split(command_and_args, " ", parts: 3) do
      nick = prefix |> String.split("!", parts: 2) |> List.first()
      Chat.record_inbound_message(connection, channel, nick, body)
    else
      _ -> :ignore
    end
  end

  defp parse_privmsg(_, _), do: :ignore

  defp send_line(%{transport: nil}, _line), do: {:error, :not_connected}

  defp send_line(%{transport: transport, socket: socket}, line),
    do: send_line(transport, socket, line)

  defp send_line(:ssl, socket, line), do: :ssl.send(socket, [line, "\r\n"])
  defp send_line(:gen_tcp, socket, line), do: :gen_tcp.send(socket, [line, "\r\n"])

  defp present?(value), do: is_binary(value) and value != ""
end
