defmodule IrcpipeWeb.UserChannel.Reply do
  def ok(socket, payload) do
    {:reply, {:ok, Map.put(payload, :reply, "ok")}, socket}
  end

  def error(socket, payload) do
    {:reply, {:error, Map.put(payload, :reply, "error")}, socket}
  end
end
