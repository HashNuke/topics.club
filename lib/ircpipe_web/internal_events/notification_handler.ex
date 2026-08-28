defmodule IrcpipeWeb.InternalEvents.NotificationHandler do
  @moduledoc false

  alias Ircpipe.Notifications.Delivery

  def dispatch(%{type: "notification_committed", data: %{notification_id: notification_id}}) do
    case Delivery.enqueue(notification_id) do
      {:ok, _result} -> :ok
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end
end
