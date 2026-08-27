defmodule Ircpipe.Irc.Session.OutboundMessages do
  @moduledoc false

  alias Ircpipe.Chat.{
    DirectMessageSender,
    MessageIngestion,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.{CommandRegistry, ConnectionLock}
  alias Ircpipe.Irc.Session.{PendingEchoes, Targets}

  def say(state, channel, body) do
    serialize(state, fn -> do_say(state, channel, body) end)
  end

  defp do_say(state, channel, body) do
    with :ok <- CommandRegistry.validate_chat_message(body),
         {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- ServerConnectionLock.ensure_active(state.connection.id),
         :ok <- Ircxd.Client.privmsg(client, channel, body) do
      case MessageIngestion.record_channel(
             state.connection,
             channel,
             state.connection.nickname,
             body,
             "message",
             %{direction: "outgoing"},
             Targets.casemapping(state)
           ) do
        {:ok, _message} -> {:ok, remember_pending_echo(state, channel, body, "message")}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      error -> {error, state}
    end
  end

  def action(state, channel, body) do
    serialize(state, fn -> do_action(state, channel, body) end)
  end

  defp do_action(state, channel, body) do
    with :ok <- CommandRegistry.validate_chat_message(body),
         {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- ServerConnectionLock.ensure_active(state.connection.id),
         :ok <- Ircxd.Client.privmsg(client, channel, <<1, "ACTION ", body::binary, 1>>) do
      case MessageIngestion.record_channel(
             state.connection,
             channel,
             state.connection.nickname,
             body,
             "action",
             %{direction: "outgoing"},
             Targets.casemapping(state)
           ) do
        {:ok, _message} -> {:ok, remember_pending_echo(state, channel, body, "action")}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      error -> {error, state}
    end
  end

  def direct(state, thread_id, body) do
    serialize(state, fn -> do_direct(state, thread_id, body) end)
  end

  defp do_direct(state, thread_id, body) do
    with {:ok, client} <- fetch_client(state),
         :ok <- ServerConnectionLock.ensure_active(state.connection.id),
         {:ok, %{thread: thread, message: message}} <-
           DirectMessageSender.send(
             state.connection,
             thread_id,
             body,
             fn peer_nick ->
               with :ok <- CommandRegistry.validate_private_message(peer_nick, body) do
                 Ircxd.Client.privmsg(client, peer_nick, body)
               end
             end
           ) do
      {{:ok, %{thread: thread, message: message}},
       remember_pending_echo(state, thread.peer_nick, body, "message")}
    else
      error -> {error, state}
    end
  end

  defp serialize(state, callback) do
    case state.connection do
      %ServerConnection{id: id, user_id: user_id}
      when is_integer(id) and is_integer(user_id) ->
        case ConnectionLock.run_serialized(state.connection, callback) do
          {:error, reason} -> {{:error, reason}, state}
          result -> result
        end

      %ServerConnection{} ->
        callback.()
    end
  end

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp fetch_joined_client(state, channel) do
    normalized = Targets.key(state, channel)

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
