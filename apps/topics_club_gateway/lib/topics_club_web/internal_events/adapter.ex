defmodule TopicsClubWeb.InternalEvents.Adapter do
  @moduledoc false

  @behaviour TopicsClub.InternalEvent.Adapter

  alias TopicsClubWeb.InternalEvents.{NotificationHandler, RealtimeHandler}

  @impl true
  def dispatch(%{type: "notification_committed"} = event),
    do: NotificationHandler.dispatch(event)

  def dispatch(event), do: RealtimeHandler.dispatch(event)
end
