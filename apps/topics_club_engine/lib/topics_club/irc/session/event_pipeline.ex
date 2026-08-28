defmodule TopicsClub.Irc.Session.EventPipeline do
  @moduledoc false

  alias TopicsClub.Irc.Session.{
    CommandLifecycle,
    EventRecorder,
    JoinReconciliation,
    Registration
  }

  alias Ircxd.Client.Event

  def handle(state, %Event{} = event) do
    suppress_legacy? = CommandLifecycle.suppress_legacy_output?(state, event)

    state =
      state
      |> Registration.refresh(event.name)
      |> CommandLifecycle.process_event(event)
      |> JoinReconciliation.reconcile_event(event)

    cond do
      JoinReconciliation.failure_event?(event) ->
        maybe_record_membership_failure(event, state)
        {:handled, state}

      suppress_legacy? ->
        {:handled, state}

      true ->
        {:legacy, event.legacy, state}
    end
  end

  defp maybe_record_membership_failure(%Event{name: name, payload: payload}, state)
       when name in [:irc_error, :error],
       do: EventRecorder.irc_error(state, payload)

  defp maybe_record_membership_failure(%Event{}, _state), do: :ok
end
