defmodule TopicsClub.InternalEvents.PubSubAdapter do
  @moduledoc false

  @behaviour TopicsClub.InternalEvent.Adapter

  @topic "topics_club:internal_events:v1"

  def topic, do: @topic

  @impl true
  def dispatch(event) do
    Phoenix.PubSub.broadcast(
      TopicsClub.PubSub,
      @topic,
      {__MODULE__, event}
    )
  end
end
