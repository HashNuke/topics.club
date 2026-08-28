defmodule Ircpipe.Irc.Session.UnhandledEvents do
  @moduledoc false

  require Logger

  @log_interval_seconds 60

  def handle(state, event) do
    event_name = event_name(event)
    now = System.monotonic_time(:second)
    ignored_event_logs = Map.get(state, :ignored_event_logs, %{})

    if now - Map.get(ignored_event_logs, event_name, now - @log_interval_seconds - 1) >=
         @log_interval_seconds do
      Logger.debug("Ignoring unhandled ircxd event #{event_name}")
      Map.put(state, :ignored_event_logs, Map.put(ignored_event_logs, event_name, now))
    else
      state
    end
  end

  defp event_name(name) when is_atom(name), do: Atom.to_string(name)

  defp event_name(event) when is_tuple(event) and tuple_size(event) > 0 do
    case elem(event, 0) do
      name when is_atom(name) -> Atom.to_string(name)
      name when is_binary(name) -> name
      _unsupported_name -> "unknown"
    end
  end

  defp event_name(_event), do: "unknown"
end
