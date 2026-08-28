defmodule IrcpipeWeb.UserChannel.CommandHandlerTest do
  use ExUnit.Case, async: true

  alias IrcpipeWeb.UserChannel.CommandHandler

  test "suggests and parses supported commands" do
    socket = socket()

    assert {:reply, {:ok, %{reply: "ok", commands: [suggestion]}}, ^socket} =
             CommandHandler.suggest("/jo", socket)

    assert suggestion.name == "/join"

    assert {:reply, {:ok, %{reply: "ok", command: command}}, ^socket} =
             CommandHandler.parse("/msg NickServ help", socket)

    assert command.name == "msg"
    assert command.args == ["NickServ", "help"]
  end

  test "generates a command id before rejecting a missing buffer" do
    socket = socket()

    assert {:reply,
            {:error,
             %{
               reply: "error",
               reason: "invalid_buffer",
               command_id: command_id,
               command: %{name: "join", args: ["#elixir"]}
             }}, returned_socket} =
             CommandHandler.run(%{"input" => "/join #elixir"}, socket)

    assert is_binary(command_id)
    assert returned_socket.assigns.command_id == command_id
  end

  test "preserves a caller-supplied command id in errors and socket state" do
    socket = socket()

    assert {:reply,
            {:error,
             %{
               reply: "error",
               reason: "unknown_command",
               command: "wat",
               command_id: "command-123"
             }}, returned_socket} =
             CommandHandler.run(
               %{"input" => "/wat", "command_id" => "command-123"},
               socket
             )

    assert returned_socket.assigns.command_id == "command-123"
  end

  defp socket do
    %Phoenix.Socket{assigns: %{current_user: %{id: 1}}}
  end
end
