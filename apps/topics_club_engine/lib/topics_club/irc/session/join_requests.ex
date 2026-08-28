defmodule TopicsClub.Irc.Session.JoinRequests do
  @moduledoc false

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat

  alias TopicsClub.Chat.{
    ChannelJoinRequest,
    ChannelMembership,
    MembershipLookup,
    ServerConnection,
    ServerConnectionLock
  }

  alias TopicsClub.Irc.{ConnectionLock, Session.JoinLifecycle, Session.Targets}

  def request(
        %{connection: %ServerConnection{user_id: user_id}} = state,
        %User{id: user_id} = user,
        channel
      ) do
    case ConnectionLock.run_serialized(state.connection, fn ->
           request_active(state, user, channel)
         end) do
      {:error, reason} -> {{:error, reason}, state}
      result -> result
    end
  end

  def request(state, %User{}, _channel), do: {{:error, :invalid_connection}, state}

  defp request_active(state, user, channel) do
    with :ok <- ServerConnectionLock.ensure_active(state.connection.id) do
      do_request(state, user, channel)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp do_request(state, user, channel) do
    key = Targets.key(state, channel)

    if MapSet.member?(state.pending_joins, key) do
      pending_reply(state, channel, key)
    else
      persist_and_transmit(state, user, channel)
    end
  end

  defp pending_reply(state, channel, key) do
    case MembershipLookup.find_by_channel(state.connection, channel, Targets.casemapping(state)) do
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
           ChannelJoinRequest.request(
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
