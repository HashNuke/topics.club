defmodule Ircpipe.Irc.Session.InboundMessageRouting do
  @moduledoc false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Irc.EventFormatting

  alias Ircpipe.Irc.Session.{
    Identity,
    PendingEchoes,
    Targets
  }

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
    {echo_status, state} = pop_pending_echo(state, target, body, kind, payload)
    record(echo_status, state, target, nick, body, kind, payload)
    state
  end

  defp pop_pending_echo(state, target, body, kind, %{nick: nick} = payload) do
    if Identity.source_self?(state, payload, nick) do
      case PendingEchoes.pop(
             state.pending_echoes,
             Targets.normalize(state, target),
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

  defp record(:matched, _state, _target, _nick, _body, _kind, _payload), do: :ok

  defp record(:unmatched_self, state, target, nick, body, kind, payload) do
    record_outgoing_echo(state, target, nick, body, kind, payload)
  end

  defp record(:incoming, state, target, nick, body, kind, payload) do
    record_received_message(state, target, nick, body, kind, payload)
  end

  defp record_outgoing_echo(state, target, nick, body, kind, payload) do
    metadata =
      payload
      |> EventFormatting.sender_metadata()
      |> Map.merge(%{direction: "outgoing", peer_nick: target, target: target})

    if channel = Targets.channel(state, target) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state)
      )
    else
      record_direct_received_line(
        state.connection,
        target,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state)
      )
    end
  end

  defp record_received_message(state, target, nick, body, kind, payload) do
    metadata =
      payload
      |> EventFormatting.sender_metadata()
      |> Map.merge(%{direction: "incoming", peer_nick: nick, target: target})

    if channel = Targets.channel(state, target) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        Targets.casemapping(state)
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
          Targets.casemapping(state)
        )
      else
        record_server_received_line(
          state.connection,
          body,
          kind,
          nick,
          Map.put(metadata, :service, EventFormatting.service_name(nick))
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

  defp record_server_received_line(connection, body, kind, nick, metadata) do
    Chat.record_server_message(connection, body, kind, nick, metadata)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_direct_received_line(connection, peer_nick, nick, body, kind, metadata, casemapping) do
    DirectMessageIngestion.record(connection, peer_nick, nick, body, kind, metadata, casemapping)
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
