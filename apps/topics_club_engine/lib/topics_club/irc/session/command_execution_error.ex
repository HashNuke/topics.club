defmodule TopicsClub.Irc.Session.CommandExecutionError do
  @moduledoc false

  @non_recoverable_reasons [:invalid_command_id, :duplicate_command_id]

  def present(reason) do
    %{
      code: code(reason),
      message: message(reason),
      recoverable: reason not in @non_recoverable_reasons
    }
  end

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "command_failed"

  defp message(:not_connected),
    do: "Connect to the server before running a command."

  defp message(:invalid_command_id), do: "The command identifier is invalid."
  defp message(:duplicate_command_id), do: "This command was already submitted."
  defp message(:already_joined), do: "You are already in that channel."
  defp message(:not_joined), do: "Join that channel before sending to it."

  defp message(reason),
    do: "The IRC command could not be sent: #{inspect(reason)}"
end
