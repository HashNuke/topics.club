defmodule Ircpipe.Irc.Session.JoinFailureEvents do
  @moduledoc false

  alias Ircpipe.Irc.Session.{EventRecorder, JoinReconciliation}

  def irc_error(state, payload) do
    state = JoinReconciliation.reconcile_legacy_error(state, payload)
    EventRecorder.irc_error(state, payload)
    state
  end

  def standard_reply(state, payload) do
    pending? = JoinReconciliation.pending_command?(state)
    state = JoinReconciliation.reconcile_standard_failure(state, payload)

    unless pending? do
      EventRecorder.server_line(
        state.connection,
        Map.get(payload, :description) || "JOIN failed.",
        "error"
      )
    end

    state
  end
end
