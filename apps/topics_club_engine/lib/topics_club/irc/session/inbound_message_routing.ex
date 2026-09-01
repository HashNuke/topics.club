defmodule TopicsClub.Irc.Session.InboundMessageRouting do
  @moduledoc false

  alias TopicsClub.Chat.{ConnectionLifecycle, DirectMessageIngestion, MessageIngestion}
  alias TopicsClub.Irc.EventFormatting

  alias TopicsClub.Irc.Session.{
    Identity,
    PendingEchoes,
    Targets,
    WirekeeperIngestion
  }

  @recoverable_errors [
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Ecto.ConstraintError,
    Ecto.NoResultsError,
    Ecto.StaleEntryError
  ]

  def privmsg(%{} = state, %{target: target, nick: nick, body: body} = payload) do
    case EventFormatting.action_body(Map.get(payload, :ctcp)) do
      {:ok, action} -> route(state, target, nick, action, "action", payload)
      :error -> route(state, target, nick, body, "message", payload)
    end
  end

  def notice(%{} = state, %{target: target, nick: nick, body: body} = payload) do
    route(state, target, nick, body, "notice", payload)
  end

  defp route(state, target, nick, body, kind, payload) do
    if WirekeeperIngestion.retrying?(state) do
      state
    else
      {nickname_result, state} = reconcile_self_nickname(state, nick, payload)
      {echo_status, state} = pop_pending_echo(state, target, body, kind, payload)
      ingestion = WirekeeperIngestion.context_effect("message")

      result =
        with :ok <- nickname_result do
          safely_record(fn ->
            record(echo_status, state, target, nick, body, kind, payload, ingestion)
          end)
        end

      WirekeeperIngestion.record_result(state, result)
    end
  end

  defp reconcile_self_nickname(state, nick, payload) do
    if Identity.source_self?(state, payload, nick) do
      case ConnectionLifecycle.update_nickname(state.connection, nick, "connected") do
        {:ok, connection} -> {:ok, %{state | connection: connection}}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {:ok, state}
    end
  end

  defp pop_pending_echo(state, target, body, kind, %{nick: nick} = payload) do
    if Identity.source_self?(state, payload, nick) do
      case PendingEchoes.pop(
             state.pending_echoes,
             Targets.key(state, target),
             body,
             kind
           ) do
        {:unmatched, pending_echoes} ->
          {:unmatched_self, %{state | pending_echoes: pending_echoes}}

        {:matched, pending_echoes} ->
          {:matched, %{state | pending_echoes: pending_echoes}}
      end
    else
      {:incoming, state}
    end
  end

  defp pop_pending_echo(state, _target, _body, _kind, _payload), do: {:incoming, state}

  defp record(:matched, _state, _target, _nick, _body, _kind, _payload, _ingestion),
    do: :ok

  defp record(:unmatched_self, state, target, nick, body, kind, payload, ingestion) do
    record_outgoing_echo(state, target, nick, body, kind, payload, ingestion)
  end

  defp record(:incoming, state, target, nick, body, kind, payload, ingestion) do
    record_received_message(state, target, nick, body, kind, payload, ingestion)
  end

  defp record_outgoing_echo(state, target, nick, body, kind, payload, ingestion) do
    metadata =
      payload
      |> EventFormatting.sender_metadata()
      |> Map.merge(%{direction: "outgoing", peer_nick: target, target: target})

    if channel = Targets.channel(state, target) do
      MessageIngestion.record_channel(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state),
        ingestion
      )
    else
      record_direct_received_line(
        state.connection,
        target,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state),
        ingestion
      )
    end
  end

  defp record_received_message(state, target, nick, body, kind, payload, ingestion) do
    metadata =
      payload
      |> EventFormatting.sender_metadata()
      |> Map.merge(%{direction: "incoming", peer_nick: nick, target: target})

    if channel = Targets.channel(state, target) do
      MessageIngestion.record_channel(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state),
        ingestion
      )
    else
      if user_message_source?(payload) do
        record_direct_received_line(
          state.connection,
          nick,
          nick,
          body,
          kind,
          Map.put(metadata, :service, EventFormatting.service_name(nick)),
          Targets.casemapping(state),
          ingestion
        )
      else
        record_server_received_line(
          state.connection,
          body,
          kind,
          nick,
          Map.put(metadata, :service, EventFormatting.service_name(nick)),
          ingestion
        )
      end
    end
  end

  defp user_message_source?(payload) do
    source = Map.get(payload, :source)
    raw_source = Map.get(payload, :raw_source)

    (is_map(source) and Map.get(source, :type) == :user) or
      (is_binary(raw_source) and String.contains?(raw_source, "!"))
  end

  defp record_server_received_line(connection, body, kind, nick, metadata, ingestion) do
    MessageIngestion.record_server(connection, body, kind, nick, metadata, ingestion)
  end

  defp record_direct_received_line(
         connection,
         peer_nick,
         nick,
         body,
         kind,
         metadata,
         casemapping,
         ingestion
       ) do
    DirectMessageIngestion.record(
      connection,
      peer_nick,
      nick,
      body,
      kind,
      metadata,
      casemapping,
      ingestion
    )
  end

  defp safely_record(callback) do
    callback.()
  rescue
    exception in @recoverable_errors -> {:error, {:persistence_exception, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:persistence_exit, reason}}
  end
end
