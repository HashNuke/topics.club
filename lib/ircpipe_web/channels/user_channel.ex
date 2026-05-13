defmodule IrcpipeWeb.UserChannel do
  use IrcpipeWeb, :channel

  alias Ircpipe.Irc.Commands

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

  @impl true
  def handle_in("command:suggest", %{"input" => input}, socket) do
    {:reply, {:ok, %{commands: Commands.suggest(input)}}, socket}
  end

  def handle_in("command:parse", %{"input" => input}, socket) do
    case Commands.parse(input) do
      {:ok, command} ->
        {:reply, {:ok, %{command: command}}, socket}

      {:error, :not_a_command} ->
        {:reply, {:error, %{reason: "not_a_command"}}, socket}

      {:error, {:unknown_command, command}} ->
        {:reply, {:error, %{reason: "unknown_command", command: command}}, socket}
    end
  end
end
