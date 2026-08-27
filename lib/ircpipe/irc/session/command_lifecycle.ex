defmodule Ircpipe.Irc.Session.CommandLifecycle do
  @moduledoc false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelMembership, CommandMessages}
  alias Ircpipe.Irc.CommandResult
  alias Ircpipe.Irc.Session.{Identity, Targets}
  alias Ircxd.Client.{Event, Info}
  alias Ircxd.Message

  @command_grace_timeout 300
  @command_timeout 15_000

  def validate_id(command_id, state) when is_binary(command_id) do
    cond do
      not String.match?(command_id, ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z/) ->
        {:error, :invalid_command_id}

      Map.has_key?(state.pending_commands, command_id) ->
        {:error, :duplicate_command_id}

      true ->
        :ok
    end
  end

  def validate_id(_command_id, _state), do: {:error, :invalid_command_id}

  def label(message, command_id, %{client_info: %Info{} = info}) do
    if MapSet.member?(info.active_caps, "labeled-response") do
      {%{message | tags: Map.put(message.tags, "label", command_id)}, true}
    else
      {message, false}
    end
  end

  def label(message, _command_id, _state), do: {message, false}

  def track(state, intent, message, invocation, command_id, buffer_id, labeled?) do
    terminal_events = effective_terminal_events(message.command, intent.spec)

    if labeled? or intent.spec.result_events != [] or terminal_events != [] do
      pending = %{
        command_id: command_id,
        buffer_id: buffer_id,
        command: message.command,
        targets: correlation_targets(state, message),
        spec: Map.put(intent.spec, :terminal_events, terminal_events),
        invocation: invocation,
        labeled?: labeled?,
        timer: Process.send_after(self(), {:command_timeout, command_id}, @command_timeout)
      }

      %{state | pending_commands: Map.put(state.pending_commands, command_id, pending)}
    else
      state
    end
  end

  def process_event(state, %Event{name: :labeled_request, payload: payload}) do
    command_id = Map.get(payload, :label)

    case Map.get(state.pending_commands, command_id) do
      nil ->
        state

      pending ->
        status = payload |> Map.get(:status) |> lifecycle_status()
        update_status(pending, status, lifecycle_metadata(payload))

        if status in ["completed", "failed"] do
          finish(state, command_id, pending)
        else
          state
        end
    end
  end

  def process_event(state, %Event{derivative?: true}), do: state

  def process_event(state, %Event{} = event) do
    case pending_for_event(state, event) do
      {command_id, pending} ->
        state = maybe_record_result(state, event, pending)

        cond do
          not pending.labeled? and pending.command != "JOIN" and
            event.name in [:standard_reply, :standard_reply_error] and
              Map.get(event.payload, :type) == :fail ->
            update_status(pending, "failed", %{
              error: Map.get(event.payload, :description) || "Command failed."
            })

            finish(state, command_id, pending)

          not pending.labeled? and event.name in pending.spec.terminal_events ->
            update_status(pending, "completed", %{})
            finish(state, command_id, pending)

          not pending.labeled? and pending.spec.terminal_events == [] and
              event.name in pending.spec.result_events ->
            reschedule_grace(state, command_id, pending)

          true ->
            state
        end

      nil ->
        state
    end
  end

  def suppress_legacy_output?(state, %Event{name: name}) when name in [:motd_start, :motd] do
    state
    |> Map.get(:pending_commands, %{})
    |> Enum.any?(fn {_command_id, pending} -> pending.command == "MOTD" end)
  end

  def suppress_legacy_output?(_state, %Event{}), do: false

  def timeout(state, command_id) do
    case Map.pop(state.pending_commands, command_id) do
      {nil, _pending_commands} ->
        state

      {pending, pending_commands} ->
        update_status(pending, "timed_out", %{error: "No server response was received."})
        %{state | pending_commands: pending_commands}
    end
  end

  def grace_timeout(state, command_id) do
    case Map.pop(state.pending_commands, command_id) do
      {nil, _pending_commands} ->
        state

      {pending, pending_commands} ->
        update_status(pending, "completed", %{})
        %{state | pending_commands: pending_commands}
    end
  end

  def fail_all(state, reason) do
    Enum.each(Map.get(state, :pending_commands, %{}), fn {_command_id, pending} ->
      Process.cancel_timer(pending.timer)
      update_status(pending, "failed", %{error: reason})
    end)

    Map.put(state, :pending_commands, %{})
  end

  def finish(state, command_id, pending) do
    Process.cancel_timer(pending.timer)
    %{state | pending_commands: Map.delete(state.pending_commands, command_id)}
  end

  def update_status(pending, status, metadata) do
    CommandMessages.update(
      pending.invocation,
      Map.merge(metadata, %{command_status: status})
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  def execution_error(reason) do
    %{
      code: error_code(reason),
      message: execution_message(reason),
      recoverable: reason not in [:invalid_command_id, :duplicate_command_id]
    }
  end

  defp correlation_targets(state, %Message{command: command, params: [targets | _rest]})
       when command in ["JOIN", "PART", "PRIVMSG", "NOTICE"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_target(state, &1))
  end

  defp correlation_targets(state, %Message{command: command, params: [target | _rest]})
       when command in ["NICK", "TOPIC", "MODE", "KICK", "INVITE"] do
    [normalize_target(state, target)]
  end

  defp correlation_targets(state, %Message{command: command, params: params})
       when command in ["ISON", "USERHOST"] do
    Enum.map(params, &normalize_target(state, &1))
  end

  defp correlation_targets(state, %Message{command: "WHOIS", params: params}) do
    case List.last(params) do
      target when is_binary(target) -> [normalize_target(state, target)]
      _target -> []
    end
  end

  defp correlation_targets(state, %Message{command: command, params: [targets | _rest]})
       when command in ["LIST", "NAMES", "WHO", "WHOWAS"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_target(state, &1))
  end

  defp correlation_targets(_state, %Message{}), do: []

  defp normalize_target(state, target) do
    if Targets.channel?(state, target),
      do: Targets.key(state, target),
      else: Targets.normalize(state, target)
  end

  defp effective_terminal_events(command, spec) do
    application_events =
      case {command, spec.family} do
        {"AWAY", _family} -> [:away, :now_away, :unaway]
        {"INVITE", _family} -> [:inviting, :invite]
        {"JOIN", _family} -> [:join]
        {"KICK", _family} -> [:kick]
        {"MODE", :mutation} -> [:mode]
        {"NICK", _family} -> [:nick]
        {"PART", _family} -> [:part]
        {"QUIT", _family} -> [:disconnect, :disconnected]
        {"TOPIC", :mutation} -> [:topic]
        {_command, _family} -> []
      end

    Enum.uniq(spec.terminal_events ++ application_events)
  end

  defp pending_for_event(state, %Event{label: label}) when is_binary(label) do
    case Map.get(state.pending_commands, label) do
      nil -> nil
      pending -> {label, pending}
    end
  end

  defp pending_for_event(state, %Event{} = event) do
    state.pending_commands
    |> Enum.filter(fn {_command_id, pending} ->
      not pending.labeled? and event_matches_pending?(state, event, pending)
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :join, payload: payload},
         %{command: "JOIN"} = pending
       ) do
    self_event?(state, payload, Map.get(payload, :nick)) and
      target_matches?(state, Map.get(payload, :channel), pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :part, payload: payload},
         %{command: "PART"} = pending
       ) do
    self_event?(state, payload, Map.get(payload, :nick)) and
      target_matches?(state, Map.get(payload, :channel), pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :nick, payload: payload},
         %{command: "NICK"} = pending
       ) do
    self_event?(state, payload, Map.get(payload, :old_nick)) and
      target_matches?(state, Map.get(payload, :new_nick), pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :topic, payload: payload},
         %{command: "TOPIC"} = pending
       ) do
    pending.spec.family == :mutation and
      self_event?(state, payload, Map.get(payload, :nick)) and
      target_matches?(state, Map.get(payload, :channel), pending.targets)
  end

  defp event_matches_pending?(state, %Event{name: name, payload: payload}, pending)
       when name in [:standard_reply, :standard_reply_error] do
    Map.get(payload, :command) == pending.command and
      standard_reply_target_matches?(state, payload, pending.targets)
  end

  defp event_matches_pending?(state, %Event{name: name} = event, pending) do
    name in (pending.spec.result_events ++ pending.spec.terminal_events) and
      query_target_matches?(state, event, pending.targets)
  end

  defp query_target_matches?(_state, _event, []), do: true

  defp query_target_matches?(state, %Event{payload: payload}, targets) when is_map(payload) do
    candidates =
      [:channel, :target, :nick, :mask]
      |> Enum.map(&Map.get(payload, &1))
      |> Enum.filter(&is_binary/1)

    candidates == [] or Enum.any?(candidates, &target_matches?(state, &1, targets))
  end

  defp query_target_matches?(_state, _event, _targets), do: true

  defp standard_reply_target_matches?(_state, _payload, []), do: true

  defp standard_reply_target_matches?(state, payload, targets) do
    case Map.get(payload, :context, []) do
      [] ->
        true

      context ->
        Enum.any?(context, fn
          value when is_binary(value) -> normalize_target(state, value) in targets
          _value -> false
        end)
    end
  end

  defp self_event?(state, payload, nick) do
    Identity.event_self?(state, payload, :source_self?, nick)
  end

  def target_matches?(state, target, targets) when is_binary(target),
    do: normalize_target(state, target) in targets

  def target_matches?(_state, _target, _targets), do: false

  defp maybe_record_result(state, event, pending) do
    if result_event?(event, pending) do
      formatted = CommandResult.format(event)

      metadata =
        Map.merge(formatted.metadata, %{
          command_id: pending.command_id,
          command: pending.command,
          command_status: "result"
        })

      _result =
        CommandMessages.record(
          state.connection,
          result_buffer_id(state, event, pending),
          formatted.body,
          metadata
        )
    end

    state
  end

  defp result_event?(%Event{name: name}, pending) do
    name in pending.spec.result_events or name in [:standard_reply, :standard_reply_error]
  end

  defp result_buffer_id(state, event, pending) do
    channel =
      if is_map(event.payload) do
        Map.get(event.payload, :channel) || Map.get(event.payload, :target)
      end

    if is_binary(channel) and Targets.channel?(state, channel) do
      case Chat.get_channel_membership(state.connection, channel, Targets.casemapping(state)) do
        %ChannelMembership{id: membership_id, status: status}
        when status in ["pending", "joined"] ->
          "channel:#{membership_id}"

        _membership ->
          pending.buffer_id
      end
    else
      pending.buffer_id
    end
  end

  defp reschedule_grace(state, command_id, pending) do
    Process.cancel_timer(pending.timer)

    pending = %{
      pending
      | timer:
          Process.send_after(
            self(),
            {:command_grace_timeout, command_id},
            @command_grace_timeout
          )
    }

    %{state | pending_commands: Map.put(state.pending_commands, command_id, pending)}
  end

  defp lifecycle_status(:sent), do: "sent"
  defp lifecycle_status(:acknowledged), do: "acknowledged"
  defp lifecycle_status(:completed), do: "completed"
  defp lifecycle_status(:failed), do: "failed"
  defp lifecycle_status(_status), do: "sent"

  defp lifecycle_metadata(payload) do
    case Map.get(payload, :reason) do
      nil -> %{}
      reason -> %{error: inspect(reason)}
    end
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "command_failed"

  defp execution_message(:not_connected),
    do: "Connect to the server before running a command."

  defp execution_message(:invalid_command_id), do: "The command identifier is invalid."
  defp execution_message(:duplicate_command_id), do: "This command was already submitted."
  defp execution_message(:already_joined), do: "You are already in that channel."
  defp execution_message(:not_joined), do: "Join that channel before sending to it."

  defp execution_message(reason),
    do: "The IRC command could not be sent: #{inspect(reason)}"
end
