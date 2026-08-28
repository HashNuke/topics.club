defmodule TopicsClubWeb.UserChannel.ReplyTest do
  use ExUnit.Case, async: true

  alias TopicsClubWeb.UserChannel.Reply

  test "builds successful channel replies" do
    socket = %Phoenix.Socket{}

    assert {:reply, {:ok, %{reply: "ok", value: 1}}, ^socket} =
             Reply.ok(socket, %{value: 1})
  end

  test "builds error channel replies" do
    socket = %Phoenix.Socket{}

    assert {:reply, {:error, %{reply: "error", reason: "invalid_buffer"}}, ^socket} =
             Reply.error(socket, %{reason: "invalid_buffer"})
  end
end
