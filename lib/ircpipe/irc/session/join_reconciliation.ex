defmodule Ircpipe.Irc.Session.JoinReconciliation do
  @moduledoc false

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session.{CommandLifecycle, Targets}
  alias Ircxd.Client.Event

  def failure_event?(%Event{name: name, payload: payload})
      when name in [:irc_error, :error],
      do: Map.get(payload, :code) in ~w(403 405 461 471 473 474 475 476 477)

  def failure_event?(%Event{name: name, payload: payload})
      when name in [:standard_reply, :standard_reply_error],
      do: Map.get(payload, :type) == :fail and Map.get(payload, :command) == "JOIN"

  def failure_event?(%Event{}), do: false

  def pending_command?(state), do: not is_nil(oldest_pending_join(state, nil))

  def reconcile_legacy_error(state, %{code: "461", target: target} = payload)
      when is_binary(target) do
    if String.upcase(target) == "JOIN" do
      reject_targets(state, pending_join_targets(state), Map.get(payload, :reason) || "461")
    else
      state
    end
  end

  def reconcile_legacy_error(state, %{code: code, target: target} = payload)
      when code in ~w(403 405 471 473 474 475 476 477) and is_binary(target) do
    if pending_target?(state, target) do
      reject_targets(state, [target], Map.get(payload, :reason) || code)
    else
      state
    end
  end

  def reconcile_legacy_error(state, %{code: "442", target: target} = payload)
      when is_binary(target) do
    if Targets.channel?(state, target) do
      Chat.reject_channel_part(
        state.connection,
        target,
        Map.get(payload, :reason) || "442",
        Targets.casemapping(state)
      )
    end

    state
  end

  def reconcile_legacy_error(state, _payload), do: state

  def reconcile_standard_failure(state, payload) do
    context_targets =
      payload
      |> Map.get(:context)
      |> List.wrap()
      |> Enum.filter(&Targets.channel?(state, &1))

    targets =
      if context_targets == [] do
        pending_join_targets(state)
      else
        Enum.filter(context_targets, &pending_target?(state, &1))
      end

    reject_targets(state, targets, Map.get(payload, :description) || "JOIN failed.")
  end

  def reconcile_event(
        state,
        %Event{name: name, payload: %{code: "461", target: target} = payload} = event
      )
      when name in [:irc_error, :error] and is_binary(target) do
    case pending_for_event(state, event) do
      {command_id, pending} ->
        if String.upcase(target) == "JOIN" do
          reject_targets(
            state,
            pending.targets,
            Map.get(payload, :reason) || "461",
            {command_id, pending}
          )
        else
          state
        end

      nil ->
        if is_nil(event.label) and String.upcase(target) == "JOIN" do
          reject_unambiguous_native(state, Map.get(payload, :reason) || "461")
        else
          state
        end
    end
  end

  def reconcile_event(
        state,
        %Event{name: name, payload: %{code: code, target: target} = payload} = event
      )
      when name in [:irc_error, :error] and code in ~w(403 405 471 473 474 475 476 477) and
             is_binary(target) do
    case pending_for_event(state, event) do
      {command_id, pending} ->
        if CommandLifecycle.target_matches?(state, target, pending.targets) do
          reject_targets(
            state,
            [target],
            Map.get(payload, :reason) || code,
            {command_id, pending}
          )
        else
          state
        end

      nil ->
        if is_nil(event.label) and pending_target?(state, target) do
          reject_targets(state, [target], Map.get(payload, :reason) || code, :native_only)
        else
          state
        end
    end
  end

  def reconcile_event(
        state,
        %Event{name: name, payload: %{type: :fail, command: "JOIN"} = payload} = event
      )
      when name in [:standard_reply, :standard_reply_error] do
    case pending_for_event(state, event) do
      {command_id, pending} ->
        context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&CommandLifecycle.target_matches?(state, &1, pending.targets))

        all_context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&Targets.channel?(state, &1))

        if all_context_targets != [] and context_targets == [] do
          state
        else
          targets = if context_targets == [], do: pending.targets, else: context_targets

          reject_targets(
            state,
            targets,
            Map.get(payload, :description) || "JOIN failed.",
            {command_id, pending}
          )
        end

      nil ->
        context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&pending_target?(state, &1))

        cond do
          not is_nil(event.label) ->
            record_unmatched_failure(state, payload)

          context_targets != [] ->
            reject_targets(
              state,
              context_targets,
              Map.get(payload, :description) || "JOIN failed.",
              :native_only
            )

          true ->
            reject_unambiguous_native(
              state,
              Map.get(payload, :description) || "JOIN failed.",
              payload
            )
        end
    end
  end

  def reconcile_event(state, %Event{}), do: state

  defp reject_targets(state, targets, reason, correlated_pending \\ :match_unlabeled) do
    targets = Enum.map(targets, &Targets.key(state, &1))

    Enum.each(
      targets,
      &Chat.reject_channel_join(state.connection, &1, reason, Targets.casemapping(state))
    )

    state =
      state
      |> Map.update(:pending_joins, MapSet.new(), fn pending_joins ->
        Enum.reduce(targets, pending_joins, &MapSet.delete(&2, &1))
      end)
      |> Map.update(:sent_joins, MapSet.new(), fn sent_joins ->
        Enum.reduce(targets, sent_joins, &MapSet.delete(&2, &1))
      end)

    case correlated_pending do
      {command_id, pending} ->
        CommandLifecycle.update_status(pending, "failed", %{error: reason})
        CommandLifecycle.finish(state, command_id, pending)

      :match_unlabeled ->
        maybe_fail_unlabeled(state, targets, reason)

      :native_only ->
        state
    end
  end

  defp reject_unambiguous_native(state, reason, unmatched_payload \\ nil) do
    command_targets =
      state.pending_commands
      |> Enum.flat_map(fn
        {_command_id, %{command: "JOIN", targets: targets}} -> targets
        _pending -> []
      end)
      |> MapSet.new()

    native_targets =
      state
      |> Map.get(:sent_joins, MapSet.new())
      |> MapSet.difference(command_targets)
      |> MapSet.to_list()

    case native_targets do
      [target] ->
        reject_targets(state, [target], reason, :native_only)

      _targets when is_map(unmatched_payload) ->
        record_unmatched_failure(state, unmatched_payload)

      _targets ->
        state
    end
  end

  defp record_unmatched_failure(state, payload) do
    record_server_error(
      state.connection,
      Map.get(payload, :description) || Map.get(payload, :reason) || "JOIN failed."
    )

    state
  end

  defp maybe_fail_unlabeled(state, rejected_targets, reason) do
    case pending_matching_targets(state, rejected_targets, false) do
      {command_id, %{targets: targets} = pending} ->
        if targets != [] and targets -- rejected_targets == [] do
          CommandLifecycle.update_status(pending, "failed", %{error: reason})
          CommandLifecycle.finish(state, command_id, pending)
        else
          state
        end

      _pending ->
        state
    end
  end

  defp pending_for_event(state, %Event{label: label}) when is_binary(label) do
    case Map.get(state.pending_commands, label) do
      %{command: "JOIN"} = pending -> {label, pending}
      _pending -> nil
    end
  end

  defp pending_for_event(state, %Event{payload: payload}) do
    targets =
      [Map.get(payload, :target) | List.wrap(Map.get(payload, :context))]
      |> Enum.filter(&Targets.channel?(state, &1))
      |> Enum.map(&Targets.key(state, &1))

    if targets == [],
      do: oldest_pending_join(state, false),
      else: pending_matching_targets(state, targets, false)
  end

  defp pending_matching_targets(state, targets, labeled?) do
    normalized_targets = Enum.map(targets, &Targets.key(state, &1))

    state
    |> Map.get(:pending_commands, %{})
    |> Enum.filter(fn {_command_id, pending} ->
      pending.command == "JOIN" and pending.labeled? == labeled? and
        Enum.any?(normalized_targets, &(&1 in pending.targets))
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp pending_join_targets(state) do
    case oldest_pending_join(state, nil) do
      {_command_id, pending} -> pending.targets
      nil -> []
    end
  end

  defp pending_target?(state, target) do
    normalized = Targets.key(state, target)

    MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
      Enum.any?(Map.get(state, :pending_commands, %{}), fn
        {_command_id, %{command: "JOIN", targets: targets}} -> normalized in targets
        _other -> false
      end)
  end

  defp oldest_pending_join(state, labeled?) do
    state
    |> Map.get(:pending_commands, %{})
    |> Enum.filter(fn {_command_id, pending} ->
      pending.command == "JOIN" and (is_nil(labeled?) or pending.labeled? == labeled?)
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp record_server_error(connection, body) do
    Chat.record_server_message(connection, body, "error")
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end
end
