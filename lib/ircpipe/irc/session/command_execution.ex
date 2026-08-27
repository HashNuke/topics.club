defmodule Ircpipe.Irc.Session.CommandExecution do
  @moduledoc false

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    ChannelJoinRequest,
    CommandMessages,
    DirectMessageIngestion,
    MessageIngestion
  }

  alias Ircpipe.Irc.{CommandRegistry, ConnectionLock}
  alias Ircpipe.Irc.Session.{CommandLifecycle, PendingEchoes, Targets}
  alias Ircpipe.Repo

  def execute(state, intent, command_id, buffer_id) do
    case ConnectionLock.run_serialized(state.connection, fn ->
           do_execute(state, intent, command_id, buffer_id)
         end) do
      {:error, reason} -> {{:error, CommandLifecycle.execution_error(reason)}, state}
      result -> result
    end
  end

  defp do_execute(state, intent, command_id, buffer_id) do
    with :ok <- CommandLifecycle.validate_id(command_id, state),
         {:ok, client} <- fetch_registered_client(state),
         :ok <- prepare(state, intent),
         {:ok, invocation} <- record_invocation(state, intent, command_id, buffer_id),
         {message, labeled?} <- CommandLifecycle.label(intent.message, command_id, state) do
      transmit(state, intent, invocation, message, labeled?, command_id, buffer_id, client)
    else
      {:error, %{code: _code} = error} -> {{:error, error}, state}
      {:error, reason} -> {{:error, CommandLifecycle.execution_error(reason)}, state}
    end
  end

  def prepare(
        state,
        %{disposition: :managed, message: %{command: "JOIN", params: [channels | _rest]}}
      ) do
    channels
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn channel, :ok ->
      cond do
        not Targets.channel?(state, channel) ->
          {:halt, {:error, :invalid_channel}}

        MapSet.member?(state.joined_channels, Targets.key(state, channel)) ->
          {:halt, {:error, :already_joined}}

        MapSet.member?(state.pending_joins, Targets.key(state, channel)) ->
          {:halt, {:error, :already_pending}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  def prepare(
        state,
        %{disposition: :managed, message: %{command: command, params: [targets, body]}}
      )
      when command in ["PRIVMSG", "NOTICE"] do
    with :ok <- CommandRegistry.validate_managed_body(command, body) do
      targets
      |> String.split(",", trim: true)
      |> Enum.reduce_while(:ok, fn target, :ok ->
        if Targets.channel?(state, target) and
             not MapSet.member?(state.joined_channels, Targets.key(state, target)) do
          {:halt, {:error, :not_joined}}
        else
          {:cont, :ok}
        end
      end)
    end
  end

  def prepare(state, %{message: %{command: "PART", params: [channels | _rest]}}) do
    validate_joined_targets(state, channels)
  end

  def prepare(
        state,
        %{spec: %{family: :mutation}, message: %{command: command, params: [target | _rest]}}
      )
      when command in ["KICK", "MODE", "TOPIC"] do
    if Targets.channel?(state, target), do: validate_joined_targets(state, target), else: :ok
  end

  def prepare(_state, _intent), do: :ok

  def record_invocation(state, intent, command_id, buffer_id) do
    display = invocation_display(state, intent)

    metadata = %{
      command_id: command_id,
      command: intent.message.command,
      command_status: "sent",
      disposition: Atom.to_string(intent.disposition),
      input: display
    }

    case CommandMessages.record(state.connection, buffer_id, display, metadata) do
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  def persist_outcome(
        state,
        %{disposition: :managed, message: %{command: "JOIN", params: [channels | _rest]}}
      ) do
    user = Repo.get!(User, state.connection.user_id)

    next_state =
      channels
      |> String.split(",", trim: true)
      |> Enum.reduce(state, fn channel, current_state ->
        {:ok, membership} =
          ChannelJoinRequest.request(
            user,
            state.connection,
            channel,
            Targets.casemapping(current_state)
          )

        key = Targets.key(current_state, membership.channel)

        current_state
        |> Map.update!(:pending_joins, &MapSet.put(&1, key))
        |> Map.update!(:sent_joins, &MapSet.put(&1, key))
      end)

    {next_state, %{}}
  end

  def persist_outcome(
        state,
        %{disposition: :managed, message: %{command: command, params: [targets, body]}}
      )
      when command in ["PRIVMSG", "NOTICE"] do
    {kind, body} = outgoing_kind_and_body(command, body)

    {next_state, channel_messages, direct_messages} =
      Enum.reduce(
        String.split(targets, ",", trim: true),
        {state, [], []},
        fn target, {current_state, channel_messages, direct_messages} ->
          metadata = %{direction: "outgoing", peer_nick: target, target: target}

          {channel_messages, direct_messages} =
            persist_managed_message(
              current_state,
              target,
              body,
              kind,
              metadata,
              channel_messages,
              direct_messages
            )

          {
            remember_pending_echo(current_state, target, body, kind),
            channel_messages,
            direct_messages
          }
        end
      )

    {next_state,
     %{
       channel_messages: Enum.reverse(channel_messages),
       direct_messages: Enum.reverse(direct_messages)
     }}
  end

  def persist_outcome(state, _intent), do: {state, %{}}

  defp transmit(
         state,
         intent,
         invocation,
         message,
         labeled?,
         command_id,
         buffer_id,
         client
       ) do
    case Ircxd.Client.transmit(client, message) do
      :ok ->
        {state, managed_outcome} = persist_outcome(state, intent)

        state =
          CommandLifecycle.track(
            state,
            intent,
            message,
            invocation,
            command_id,
            buffer_id,
            labeled?
          )

        reply =
          Map.merge(
            %{
              command_id: command_id,
              status: "sent",
              command: String.downcase(message.command),
              display: intent.display
            },
            managed_outcome
          )

        {{:ok, reply}, state}

      {:error, reason} ->
        CommandMessages.update(invocation, %{
          command_status: "failed",
          error: inspect(reason)
        })

        {{:error, CommandLifecycle.execution_error(reason)}, state}
    end
  end

  defp fetch_registered_client(%{registered?: true, client: client}) when not is_nil(client),
    do: {:ok, client}

  defp fetch_registered_client(_state), do: {:error, :not_connected}

  defp validate_joined_targets(state, targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if MapSet.member?(state.joined_channels, Targets.key(state, target)),
        do: {:cont, :ok},
        else: {:halt, {:error, :not_joined}}
    end)
  end

  defp invocation_display(
         state,
         %{
           display: display,
           message: %{command: command, params: [targets, _body]}
         }
       )
       when command in ["PRIVMSG", "NOTICE"] do
    if targets
       |> String.split(",", trim: true)
       |> Enum.any?(&(not Targets.channel?(state, &1))) do
      "#{command} #{targets} :[private message redacted]"
    else
      display
    end
  end

  defp invocation_display(_state, intent), do: intent.display

  defp outgoing_kind_and_body("PRIVMSG", <<1, "ACTION ", rest::binary>>) do
    {"action", String.trim_trailing(rest, <<1>>)}
  end

  defp outgoing_kind_and_body("PRIVMSG", body), do: {"message", body}
  defp outgoing_kind_and_body("NOTICE", body), do: {"notice", body}

  defp persist_managed_message(
         state,
         target,
         body,
         kind,
         metadata,
         channel_messages,
         direct_messages
       ) do
    if channel = Targets.channel(state, target) do
      case MessageIngestion.record_channel(
             state.connection,
             channel,
             state.connection.nickname,
             body,
             kind,
             metadata,
             Targets.casemapping(state)
           ) do
        {:ok, message} -> {[message | channel_messages], direct_messages}
        _error -> {channel_messages, direct_messages}
      end
    else
      case DirectMessageIngestion.record(
             state.connection,
             target,
             state.connection.nickname,
             body,
             kind,
             metadata,
             Targets.casemapping(state)
           ) do
        {:ok, %{thread: thread, message: message}} ->
          {channel_messages, [%{thread: thread, message: message} | direct_messages]}

        _error ->
          {channel_messages, direct_messages}
      end
    end
  end

  defp remember_pending_echo(state, target, body, kind) do
    pending_echoes =
      PendingEchoes.remember(
        state.pending_echoes,
        Targets.normalize(state, target),
        body,
        kind
      )

    %{state | pending_echoes: pending_echoes}
  end
end
