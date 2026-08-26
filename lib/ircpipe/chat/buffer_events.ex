defmodule Ircpipe.Chat.BufferEvents do
  @moduledoc false

  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Realtime.Event

  def left(payload) when is_map(payload) do
    broadcast_payload(:buffer_left, payload, &Event.buffer_left/1)
  end

  def read(payload) when is_map(payload) do
    broadcast_payload(:buffer_read, payload, &Event.buffer_read/1)
  end

  def joined(
        %ServerConnection{} = connection,
        %ChannelMembership{} = membership,
        status \\ nil
      ) do
    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:buffer_joined, Event.buffer_joined(connection, membership, status || connection.status)}
    )
  end

  defp broadcast_payload(event_name, payload, event_builder) do
    user_id = Map.fetch!(payload, :user_id)

    event =
      payload
      |> event_builder.()
      |> Map.drop([:user_id])

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {event_name, event}
    )
  end
end
