defmodule TopicsClub.Irc.Session.PendingEchoes do
  @moduledoc false

  @limit 200
  @ttl_ms :timer.minutes(5)

  defstruct entries: []

  @type entry :: %{
          target: String.t(),
          body: String.t(),
          kind: String.t(),
          inserted_at_ms: integer()
        }
  @type t :: %__MODULE__{entries: [entry()]}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: entries == []

  @spec remember(t(), String.t(), String.t(), String.t(), integer()) :: t()
  def remember(
        %__MODULE__{entries: entries} = pending_echoes,
        target,
        body,
        kind,
        now_ms \\ System.monotonic_time(:millisecond)
      ) do
    entry = %{target: target, body: body, kind: kind, inserted_at_ms: now_ms}
    entries = [entry | recent(entries, now_ms)] |> Enum.take(@limit)

    %{pending_echoes | entries: entries}
  end

  @spec pop(t(), String.t(), String.t(), String.t(), integer()) ::
          {:matched | :unmatched, t()}
  def pop(
        %__MODULE__{entries: entries} = pending_echoes,
        target,
        body,
        kind,
        now_ms \\ System.monotonic_time(:millisecond)
      ) do
    entries = recent(entries, now_ms)

    case Enum.split_while(entries, &(not matches?(&1, target, body, kind))) do
      {_before, []} ->
        {:unmatched, %{pending_echoes | entries: entries}}

      {before, [_matched | after_matched]} ->
        {:matched, %{pending_echoes | entries: before ++ after_matched}}
    end
  end

  defp recent(entries, now_ms) do
    cutoff = now_ms - @ttl_ms
    Enum.filter(entries, &(&1.inserted_at_ms >= cutoff))
  end

  defp matches?(entry, target, body, kind) do
    entry.target == target and entry.body == body and entry.kind == kind
  end
end
