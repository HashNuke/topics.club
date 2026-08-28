defmodule IrcpipeWeb.InternalEvents.Adapter do
  @moduledoc false

  @behaviour Ircpipe.InternalEvent.Adapter

  alias IrcpipeWeb.InternalEvents.{NotificationHandler, RealtimeHandler}

  @impl true
  def dispatch(%{type: "notification_committed"} = event),
    do: NotificationHandler.dispatch(event)

  def dispatch(event), do: RealtimeHandler.dispatch(event)
end
