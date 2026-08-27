defmodule Ircpipe.Irc.Session.JoinRequests do
  @moduledoc false

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Irc.Session.{JoinLifecycle, Targets}

  def request(
        %{connection: %ServerConnection{user_id: user_id}} = state,
        %User{id: user_id} = user,
        channel
      ) do
    key = Targets.key(state, channel)

    if MapSet.member?(state.pending_joins, key) do
      pending_reply(state, channel, key)
    else
      persist_and_transmit(state, user, channel)
    end
  end

  def request(state, %User{}, _channel), do: {{:error, :invalid_connection}, state}

  defp pending_reply(state, channel, key) do
    case Chat.get_channel_membership(state.connection, channel, Targets.casemapping(state)) do
      %ChannelMembership{} = membership ->
        status =
          if MapSet.member?(Map.get(state, :sent_joins, MapSet.new()), key),
            do: :sent,
            else: :queued

        {{:ok, membership, status}, state}

      nil ->
        {{:error, :already_pending}, state}
    end
  end

  defp persist_and_transmit(state, user, channel) do
    with :ok <- JoinLifecycle.validate(state, channel),
         {:ok, membership} <-
           Chat.request_channel_join(
             user,
             state.connection,
             channel,
             Targets.casemapping(state)
           ) do
      {reply, state} = JoinLifecycle.transmit(state, membership.channel)

      case reply do
        status when status in [:sent, :queued] ->
          {{:ok, membership, status}, state}

        error ->
          Chat.reject_channel_join(
            state.connection,
            membership.channel,
            error,
            Targets.casemapping(state)
          )

          {error, state}
      end
    else
      {:error, error} -> {{:error, error}, state}
    end
  end
end
