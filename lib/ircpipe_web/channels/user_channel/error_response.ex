defmodule IrcpipeWeb.UserChannel.ErrorResponse do
  def reason(:invalid_buffer), do: "invalid_buffer"
  def reason(:invalid_server), do: "invalid_server"
  def reason(:invalid_direct_message), do: "invalid_direct_message"
  def reason(:direct_message_closed), do: "direct_message_closed"
  def reason(:stale_direct_message), do: "stale_direct_message"
  def reason(:invalid_command_args), do: "invalid_command_args"
  def reason(:invalid_connection), do: "invalid_connection"
  def reason(:connection_deleting), do: "connection_deleting"
  def reason(:not_connected), do: "not_connected"
  def reason(:list_in_progress), do: "list_in_progress"
  def reason(:list_timeout), do: "list_timeout"
  def reason(:joining_channel), do: "joining_channel"
  def reason(:not_joined), do: "not_joined"
  def reason(%{code: :invalid_state, details: %{code: code}}), do: code
  def reason(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  def reason(%{code: code}), do: code
  def reason(_reason), do: "send_failed"

  def public_error(%{code: :invalid_state, details: details}) when map_size(details) > 0,
    do: details

  def public_error(error), do: error

  def send_body(:not_connected), do: "Message could not be sent: not connected."

  def send_body(:joining_channel),
    do: "Message could not be sent: still joining the channel."

  def send_body(:not_joined), do: "Message could not be sent: not joined to the channel."
  def send_body(%{message: message}), do: message
  def send_body(_reason), do: "Message could not be sent."
end
