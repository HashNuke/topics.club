defmodule Ircpipe.Irc.Session.CommandExecution do
  @moduledoc false

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{DirectMessageIngestion, MessageIngestion}
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.Session.{PendingEchoes, Targets}
  alias Ircpipe.Repo

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

    case Chat.record_command_message(state.connection, buffer_id, display, metadata) do
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
          Chat.request_channel_join(
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

    {next_state, direct_messages} =
      Enum.reduce(
        String.split(targets, ",", trim: true),
        {state, []},
        fn target, {current_state, direct_messages} ->
          metadata = %{direction: "outgoing", peer_nick: target, target: target}

          direct_messages =
            if channel = Targets.channel(current_state, target) do
              MessageIngestion.record_channel(
                current_state.connection,
                channel,
                current_state.connection.nickname,
                body,
                kind,
                metadata,
                Targets.casemapping(current_state)
              )

              direct_messages
            else
              case DirectMessageIngestion.record(
                     current_state.connection,
                     target,
                     current_state.connection.nickname,
                     body,
                     kind,
                     metadata,
                     Targets.casemapping(current_state)
                   ) do
                {:ok, %{thread: thread, message: message}} ->
                  [%{thread: thread, message: message} | direct_messages]

                _error ->
                  direct_messages
              end
            end

          {remember_pending_echo(current_state, target, body, kind), direct_messages}
        end
      )

    {next_state, %{direct_messages: Enum.reverse(direct_messages)}}
  end

  def persist_outcome(state, _intent), do: {state, %{}}

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
