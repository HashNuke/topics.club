defmodule Ircpipe.Irc.Session.ChannelListEvents do
  @moduledoc false

  alias Ircpipe.Irc.Session.ChannelListRequest

  def handle_irc(%{channel_list_request: request} = state, {:list_start, _payload})
      when not is_nil(request) do
    {:handled, %{state | channel_list_request: ChannelListRequest.reset(request)}}
  end

  def handle_irc(
        %{channel_list_request: request} = state,
        {:list_entry, %{channel: _channel} = payload}
      )
      when not is_nil(request) do
    {:handled, %{state | channel_list_request: ChannelListRequest.add(request, payload)}}
  end

  def handle_irc(%{channel_list_request: request} = state, {:list_end, _payload})
      when not is_nil(request) do
    {:handled, %{state | channel_list_request: ChannelListRequest.complete(request)}}
  end

  def handle_irc(_state, _event), do: :unhandled

  def timeout(
        %{channel_list_request: %{ref: ref} = request} = state,
        ref
      ) do
    %{state | channel_list_request: ChannelListRequest.expire(request)}
  end

  def timeout(state, _stale_ref), do: state
end
