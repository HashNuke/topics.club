defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if Integer.to_string(socket.assigns.current_user.id) == user_id do
      Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user_id}")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:irc_message, message}, socket) do
    push(socket, "message", message)
    {:noreply, socket}
  end

  def handle_info({:irc_mention, message}, socket) do
    push(socket, "mention", message)
    {:noreply, socket}
  end
end
