defmodule Ircpipe.Irc.Session.ChannelListRequest do
  @moduledoc false

  @timeout_ms 10_000

  def timeout_ms, do: @timeout_ms

  def new(from) do
    ref = make_ref()
    timer = Process.send_after(self(), {:channel_list_timeout, ref}, @timeout_ms)
    %{from: from, ref: ref, timer: timer, entries: %{}}
  end

  def reset(request), do: %{request | entries: %{}}

  def add(request, %{channel: channel} = payload) do
    entry = %{
      channel: channel,
      users: parse_visible_users(Map.get(payload, :visible)),
      topic: Map.get(payload, :topic) || ""
    }

    put_in(request.entries[entry.channel], entry)
  end

  def complete(request) do
    Process.cancel_timer(request.timer)

    channels =
      request.entries
      |> Map.values()
      |> Enum.sort_by(fn entry -> {-entry.users, String.downcase(entry.channel)} end)

    GenServer.reply(request.from, {:ok, channels})
    nil
  end

  def expire(request) do
    GenServer.reply(request.from, {:error, :list_timeout})
    nil
  end

  defp parse_visible_users(value) when is_integer(value), do: value

  defp parse_visible_users(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _other -> 0
    end
  end

  defp parse_visible_users(_value), do: 0
end
