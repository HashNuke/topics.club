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

  def action(%ServerConnection{} = connection, channel, body) do
    GenServer.call(via(connection), {:action, Chat.normalize_channel(channel), body})
  end

  def privmsg(%ServerConnection{} = connection, target, body) do
    GenServer.call(via(connection), {:privmsg, target, body})
  end

  def nick(%ServerConnection{} = connection, nick) do
    GenServer.call(via(connection), {:nick, nick})
  end

  def topic(%ServerConnection{} = connection, channel, topic) do
    GenServer.call(via(connection), {:topic, Chat.normalize_channel(channel), topic})
  end

  def raw(%ServerConnection{} = connection, command, params \\ []) do
    GenServer.call(via(connection), {:raw, command, params})
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
       pending_joins: persisted_channels(connection),
       joined_channels: MapSet.new(),
       names_buffers: %{},
       pending_echoes: []
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

    case Ircxd.Client.start_link(opts) do
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
        {:ircxd,
         {:privmsg, %{target: "#" <> _ = channel, nick: nick, body: body, ctcp: ctcp} = payload}},
        state
      ) do
    case action_body(ctcp) do
      {:ok, action} ->
        {echo?, state} = pop_pending_echo(state, channel, action, "action", payload)

        unless echo? do
          Chat.record_inbound_message(
            state.connection,
            channel,
            nick,
            action,
            "action",
            sender_metadata(payload)
          )
        end

      :error ->
        {echo?, state} = pop_pending_echo(state, channel, body, "message", payload)

        unless echo? do
          Chat.record_inbound_message(
            state.connection,
            channel,
            nick,
            body,
            "message",
            sender_metadata(payload)
          )
        end
    end

    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:privmsg, %{target: "#" <> _ = channel, nick: nick, body: body} = payload}},
        state
      ) do
    {echo?, state} = pop_pending_echo(state, channel, body, "message", payload)

    unless echo? do
      Chat.record_inbound_message(
        state.connection,
        channel,
        nick,
        body,
        "message",
        sender_metadata(payload)
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:notice, %{target: "#" <> _ = channel, nick: nick, body: body} = payload}},
        state
      ) do
    Chat.record_inbound_message(
      state.connection,
      channel,
      nick,
      body,
      "notice",
      sender_metadata(payload)
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:notice, %{nick: nick, body: body}}}, state) do
    record_server_line(state.connection, "#{nick}: #{body}", "notice", %{
      service: service_name(nick)
    })

    {:noreply, state}
  end

  def handle_info({:ircxd, {:welcome, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:your_host, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_created, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_info, payload}}, state) do
    record_server_line(
      state.connection,
      "#{payload.server} #{payload.version} user modes #{payload.user_modes} channel modes #{payload.channel_modes}",
      "notice"
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_start, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_end, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_missing, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:names, %{channel: channel, names: names}}}, state) do
    normalized = Chat.normalize_channel(channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    buffered_names = Map.get(names_buffers, normalized, []) ++ names

    state = Map.put(state, :names_buffers, Map.put(names_buffers, normalized, buffered_names))

    state =
      if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
           names_include_nick?(names, state.connection.nickname) do
        mark_channel_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:names_end, %{channel: channel}}}, state) do
    normalized = Chat.normalize_channel(channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    names = Map.get(names_buffers, normalized, [])

    if names != [] do
      Chat.broadcast_presence_sync(state.connection, channel, names)
    end

    state =
      state
      |> Map.put(:names_buffers, Map.delete(names_buffers, normalized))
      |> maybe_mark_channel_joined_from_names(channel, names)

    {:noreply, state}
  end

  def handle_info({:ircxd, {:join, %{channel: channel, nick: nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, channel, %{
      action: "join",
      user: %{nick: nick, role: "user", status: "online"}
    })

    record_channel_line(state.connection, channel, "join", nick, "#{nick} joined #{channel}.")

    state =
      if same_nick?(nick, state.connection.nickname) do
        mark_channel_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:part, %{channel: channel, nick: nick}}}, state) do
    Chat.broadcast_presence_diff(state.connection, channel, %{action: "part", nick: nick})
    record_channel_line(state.connection, channel, "part", nick, "#{nick} left #{channel}.")

    state =
      if same_nick?(nick, state.connection.nickname) do
        %{
          state
          | joined_channels: MapSet.delete(state.joined_channels, Chat.normalize_channel(channel))
        }
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:quit, %{nick: nick}}}, state) do
    record_channel_line_for_present_nick(state.connection, "quit", nick, fn _membership ->
      "#{nick} quit."
    end)

    Chat.broadcast_presence_diff(state.connection, nil, %{action: "quit", nick: nick})
    {:noreply, state}
  end

  def handle_info({:ircxd, {:nick, %{old_nick: old_nick, new_nick: new_nick}}}, state) do
    record_channel_line_for_present_nick(
      state.connection,
      "nick",
      old_nick,
      new_nick,
      fn _membership -> "#{old_nick} is now #{new_nick}." end
    )

    Chat.broadcast_presence_diff(state.connection, nil, %{
      action: "nick",
      old_nick: old_nick,
      new_nick: new_nick
    })

    {:noreply, state}
  end

  def handle_info({:ircxd, {:away, %{nick: nick} = payload}}, state) do
    status = if Map.get(payload, :away?), do: "away", else: "online"

    Chat.broadcast_presence_diff(state.connection, nil, %{
      action: "away",
      nick: nick,
      status: status
    })

    {:noreply, state}
  end

  def handle_info({:ircxd, {:mode, %{target: "#" <> _ = channel} = payload}}, state) do
    payload
    |> mode_presence_diffs()
    |> Enum.each(&Chat.broadcast_presence_diff(state.connection, channel, &1))

    record_channel_line(
      state.connection,
      channel,
      "mode",
      Map.get(payload, :nick),
      mode_body(payload)
    )

    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:kick, %{channel: channel, nick: nick, target_nick: target_nick} = payload}},
        state
      ) do
    Chat.broadcast_presence_diff(state.connection, channel, %{action: "part", nick: target_nick})

    record_channel_line(
      state.connection,
      channel,
      "kick",
      nick,
      kick_body(payload)
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:topic, %{channel: channel, nick: nick, topic: topic}}}, state) do
    record_channel_line(
      state.connection,
      channel,
      "topic",
      nick,
      "#{nick} changed the topic to: #{topic}"
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:irc_error, payload}}, state) do
    record_irc_error(state.connection, payload)
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
    with {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, body) do
      Chat.record_inbound_message(state.connection, channel, state.connection.nickname, body)
      {:reply, :ok, remember_pending_echo(state, channel, body, "message")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:action, channel, body}, _from, state) do
    with {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, <<1, "ACTION ", body::binary, 1>>) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        state.connection.nickname,
        body,
        "action"
      )

      {:reply, :ok, remember_pending_echo(state, channel, body, "action")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:privmsg, target, body}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.privmsg(client, target, body) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:nick, nick}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.nick(client, nick) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:topic, channel, topic}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.topic(client, channel, topic) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:raw, command, params}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.raw(client, command, params) do
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
    DBConnection.ConnectionError -> {:ok, connection}
    Ecto.NoResultsError -> {:ok, connection}
    Ecto.StaleEntryError -> {:ok, connection}
    DBConnection.OwnershipError -> {:ok, connection}
  catch
    :exit, _reason -> {:ok, connection}
  end

  defp record_server_line(connection, body, kind \\ "system", metadata \\ %{}) do
    Chat.record_server_message(connection, body, kind, nil, metadata)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line(connection, channel, kind, nick, body) do
    Chat.record_channel_system_message(connection, channel, kind, nick, body)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line_for_present_nick(connection, kind, nick, body_fun) do
    Chat.record_channel_system_message_for_present_nick(connection, kind, nick, body_fun)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line_for_present_nick(
         connection,
         kind,
         present_nick,
         message_nick,
         body_fun
       ) do
    Chat.record_channel_system_message_for_present_nick(
      connection,
      kind,
      present_nick,
      message_nick,
      body_fun
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_irc_error(connection, %{target: "#" <> _ = channel} = payload) do
    Chat.record_channel_system_message(connection, channel, "error", nil, irc_error_body(payload))
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> record_server_line(connection, irc_error_body(payload), "error")
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_irc_error(connection, payload) do
    record_server_line(connection, irc_error_body(payload), "error")
  end

  defp irc_error_body(%{reason: reason}) when is_binary(reason), do: reason
  defp irc_error_body(%{code: code}), do: "IRC error #{code}."
  defp irc_error_body(_payload), do: "IRC error."

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp fetch_joined_client(state, channel) do
    normalized = Chat.normalize_channel(channel)

    cond do
      state.client == nil ->
        {:error, :not_connected}

      MapSet.member?(state.joined_channels, normalized) ->
        {:ok, state.client}

      MapSet.member?(state.pending_joins, normalized) ->
        {:error, :joining_channel}

      true ->
        {:error, :not_joined}
    end
  end

  defp mark_channel_joined(state, channel) do
    normalized = Chat.normalize_channel(channel)

    state
    |> Map.put(
      :pending_joins,
      MapSet.delete(Map.get(state, :pending_joins, MapSet.new()), normalized)
    )
    |> Map.put(
      :joined_channels,
      MapSet.put(Map.get(state, :joined_channels, MapSet.new()), normalized)
    )
  end

  defp maybe_mark_channel_joined_from_names(state, channel, names) do
    normalized = Chat.normalize_channel(channel)

    if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
         names_include_nick?(names, state.connection.nickname) do
      mark_channel_joined(state, channel)
    else
      state
    end
  end

  defp names_include_nick?(names, nick) when is_list(names) do
    Enum.any?(names, fn
      %{nick: listed_nick} -> same_nick?(listed_nick, nick)
      %{"nick" => listed_nick} -> same_nick?(listed_nick, nick)
      listed_nick when is_binary(listed_nick) -> same_nick?(listed_nick, nick)
      _other -> false
    end)
  end

  defp names_include_nick?(_names, _nick), do: false

  defp same_nick?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(left) == String.downcase(right)
  end

  defp same_nick?(_left, _right), do: false

  defp remember_pending_echo(state, channel, body, kind) do
    pending_echo = %{
      channel: Chat.normalize_channel(channel),
      body: body,
      kind: kind
    }

    Map.update(state, :pending_echoes, [pending_echo], fn pending_echoes ->
      [pending_echo | pending_echoes] |> Enum.take(50)
    end)
  end

  defp pop_pending_echo(state, channel, body, kind, %{nick: nick}) do
    if same_nick?(nick, state.connection.nickname) do
      pending_echoes = Map.get(state, :pending_echoes, [])

      case Enum.split_while(pending_echoes, &(not pending_echo?(&1, channel, body, kind))) do
        {_before, []} ->
          {false, state}

        {before, [_matched | after_matched]} ->
          {true, Map.put(state, :pending_echoes, before ++ after_matched)}
      end
    else
      {false, state}
    end
  end

  defp pop_pending_echo(state, _channel, _body, _kind, _payload), do: {false, state}

  defp pending_echo?(pending_echo, channel, body, kind) do
    pending_echo.channel == Chat.normalize_channel(channel) and pending_echo.body == body and
      pending_echo.kind == kind
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error

  defp action_body({:ok, %{command: "ACTION", params: params}}), do: {:ok, params}
  defp action_body(_ctcp), do: :error

  defp sender_metadata(payload) do
    %{
      hostmask: Map.get(payload, :raw_source),
      sender_role: role_from_prefixes(Map.get(payload, :prefixes, []))
    }
  end

  defp role_from_prefixes(prefixes) when is_list(prefixes) do
    cond do
      "~" in prefixes -> "owner"
      "&" in prefixes -> "admin"
      "@" in prefixes -> "op"
      "%" in prefixes -> "halfop"
      "+" in prefixes -> "voice"
      true -> nil
    end
  end

  defp role_from_prefixes(_prefixes), do: nil

  defp mode_presence_diffs(%{modes: modes, params: params}) do
    modes
    |> String.graphemes()
    |> Enum.reduce({"+", params, []}, fn
      sign, {_current_sign, remaining_params, diffs} when sign in ["+", "-"] ->
        {sign, remaining_params, diffs}

      mode, {sign, remaining_params, diffs} ->
        {nick, next_params} =
          if mode_argument?(mode, sign) do
            {List.first(remaining_params), Enum.drop(remaining_params, 1)}
          else
            {nil, remaining_params}
          end

        diff =
          if mode in ["q", "a", "o", "h", "v"] && is_binary(nick) do
            %{
              action: "role",
              nick: nick,
              role: if(sign == "+", do: role_for_mode(mode), else: "user")
            }
          end

        {sign, next_params, maybe_append(diffs, diff)}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  defp mode_presence_diffs(_payload), do: []

  defp mode_argument?(mode, _sign) when mode in ["q", "a", "o", "h", "v", "b", "e", "I", "k"],
    do: true

  defp mode_argument?("l", "+"), do: true
  defp mode_argument?(_mode, _sign), do: false

  defp role_for_mode("q"), do: "owner"
  defp role_for_mode("a"), do: "admin"
  defp role_for_mode("o"), do: "op"
  defp role_for_mode("h"), do: "halfop"
  defp role_for_mode("v"), do: "voice"

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: [item | list]

  defp service_name(nick) when is_binary(nick) do
    if String.ends_with?(nick, "Serv"), do: nick
  end

  defp service_name(_nick), do: nil

  defp mode_body(payload) do
    setter = if present?(Map.get(payload, :nick)), do: Map.get(payload, :nick), else: "server"
    modes = Map.get(payload, :modes)
    rendered_params = Enum.join(Map.get(payload, :params, []), " ")

    mode_text =
      if present?(rendered_params) do
        "#{modes} #{rendered_params}"
      else
        modes
      end

    "#{setter} set mode #{mode_text}."
  end

  defp kick_body(%{nick: nick, target_nick: target_nick, reason: reason}) do
    kicker = if present?(nick), do: nick, else: "server"

    if present?(reason) do
      "#{target_nick} was kicked by #{kicker}: #{reason}"
    else
      "#{target_nick} was kicked by #{kicker}."
    end
  end

  defp persisted_channels(%ServerConnection{channel_memberships: memberships})
       when is_list(memberships) do
    memberships
    |> Enum.map(& &1.channel)
    |> MapSet.new()
  end

  defp persisted_channels(_connection), do: MapSet.new()

  defp present?(value), do: is_binary(value) and value != ""
end
