defmodule Ircpipe.Irc.Session.CommandExecutionErrorTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.CommandExecutionError

  test "presents known execution failures as stable client errors" do
    assert CommandExecutionError.present(:not_connected) == %{
             code: "not_connected",
             message: "Connect to the server before running a command.",
             recoverable: true
           }

    assert CommandExecutionError.present(:invalid_command_id) == %{
             code: "invalid_command_id",
             message: "The command identifier is invalid.",
             recoverable: false
           }

    assert CommandExecutionError.present(:duplicate_command_id).recoverable == false
    assert CommandExecutionError.present(:already_joined).recoverable == true
    assert CommandExecutionError.present(:not_joined).recoverable == true
  end

  test "presents unknown execution failures without inventing atom codes" do
    assert CommandExecutionError.present({:transport, :closed}) == %{
             code: "command_failed",
             message: "The IRC command could not be sent: {:transport, :closed}",
             recoverable: true
           }
  end
end
