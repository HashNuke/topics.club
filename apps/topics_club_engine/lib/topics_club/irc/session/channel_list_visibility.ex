defmodule TopicsClub.Irc.Session.ChannelListVisibility do
  @moduledoc false

  alias Ircxd.Client.Event
  alias TopicsClub.Irc.ChannelListCache
  alias TopicsClub.Irc.Session.Identity

  @self_permission_events [:logged_in, :logged_out, :user_mode, :youre_oper]

  def refresh(state, %Event{} = event, opts \\ []) do
    if invalidates_cache?(state, event) do
      invalidate = Keyword.get(opts, :invalidate, &ChannelListCache.invalidate/1)
      :ok = invalidate.(state.connection)
    end

    state
  end

  def invalidates_cache?(_state, %Event{name: name}) when name in @self_permission_events,
    do: true

  def invalidates_cache?(state, %Event{name: :account, payload: payload})
      when is_map(payload) do
    Identity.source_self?(state, payload, Map.get(payload, :nick))
  end

  def invalidates_cache?(state, %Event{name: :mode, payload: payload}) when is_map(payload) do
    Identity.event_self?(state, payload, :target_self?, Map.get(payload, :target))
  end

  def invalidates_cache?(state, %Event{name: name, payload: payload})
      when name in [:join, :part] and is_map(payload) do
    Identity.source_self?(state, payload, Map.get(payload, :nick))
  end

  def invalidates_cache?(state, %Event{name: :kick, payload: payload}) when is_map(payload) do
    Identity.event_self?(state, payload, :target_self?, Map.get(payload, :target_nick))
  end

  def invalidates_cache?(_state, %Event{}), do: false
end
