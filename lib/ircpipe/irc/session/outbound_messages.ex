defmodule Ircpipe.Irc.Session.OutboundMessages do
  @moduledoc false

  alias Ircpipe.Chat.{DirectMessageSender, MessageIngestion}
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.Session.{PendingEchoes, Targets}

  def say(state, channel, body) do
    with :ok <- CommandRegistry.validate_chat_message(body),
         {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, body) do
      MessageIngestion.record_channel(
        state.connection,
        channel,
        state.connection.nickname,
        body,
        "message",
        %{direction: "outgoing"},
        Targets.casemapping(state)
      )

      {:ok, remember_pending_echo(state, channel, body, "message")}
    else
      error -> {error, state}
    end
  end

  def action(state, channel, body) do
    with :ok <- CommandRegistry.validate_chat_message(body),
         {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, <<1, "ACTION ", body::binary, 1>>) do
      MessageIngestion.record_channel(
        state.connection,
        channel,
        state.connection.nickname,
        body,
        "action",
        %{direction: "outgoing"},
        Targets.casemapping(state)
      )

      {:ok, remember_pending_echo(state, channel, body, "action")}
    else
      error -> {error, state}
    end
  end

  def direct(state, thread_id, body) do
    with {:ok, client} <- fetch_client(state),
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
