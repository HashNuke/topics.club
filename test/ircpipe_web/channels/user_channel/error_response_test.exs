defmodule IrcpipeWeb.UserChannel.ErrorResponseTest do
  use ExUnit.Case, async: true

  alias IrcpipeWeb.UserChannel.ErrorResponse

  test "maps channel and command failures to stable wire reasons" do
    assert ErrorResponse.reason(:invalid_buffer) == "invalid_buffer"
    assert ErrorResponse.reason(:invalid_server) == "invalid_server"
    assert ErrorResponse.reason(:invalid_direct_message) == "invalid_direct_message"
    assert ErrorResponse.reason(:direct_message_closed) == "direct_message_closed"
    assert ErrorResponse.reason(:stale_direct_message) == "stale_direct_message"
    assert ErrorResponse.reason(:invalid_command_args) == "invalid_command_args"
    assert ErrorResponse.reason(:invalid_connection) == "invalid_connection"
    assert ErrorResponse.reason(:connection_deleting) == "connection_deleting"
    assert ErrorResponse.reason(:not_connected) == "not_connected"
    assert ErrorResponse.reason(:list_in_progress) == "list_in_progress"
    assert ErrorResponse.reason(:list_timeout) == "list_timeout"
    assert ErrorResponse.reason(:joining_channel) == "joining_channel"
    assert ErrorResponse.reason(:not_joined) == "not_joined"
    assert ErrorResponse.reason(%{code: "protocol_owned"}) == "protocol_owned"
    assert ErrorResponse.reason(%{code: :not_connected, details: %{}}) == "not_connected"

    assert ErrorResponse.reason(%{
             code: :invalid_state,
             details: %{code: "protocol_owned"}
           }) == "protocol_owned"

    assert ErrorResponse.reason(%{
             code: :invalid_state,
             details: %{reason: "joining_channel"}
           }) == "joining_channel"

    assert ErrorResponse.reason(:unexpected) == "send_failed"
  end

  test "unwraps stable engine errors for the existing browser payload" do
    details = %{code: "protocol_owned", message: "The engine owns PING."}

    assert ErrorResponse.public_error(%{code: :invalid_state, details: details}) == details

    assert ErrorResponse.public_error(%{code: :not_connected, details: %{}}) == %{
             code: :not_connected,
             details: %{}
           }
  end

  test "builds useful message-send failure text" do
    assert ErrorResponse.send_body(:not_connected) ==
             "Message could not be sent: not connected."

    assert ErrorResponse.send_body(:joining_channel) ==
             "Message could not be sent: still joining the channel."

    assert ErrorResponse.send_body(:not_joined) ==
             "Message could not be sent: not joined to the channel."

    assert ErrorResponse.send_body(%{message: "Server rejected the command."}) ==
             "Server rejected the command."

    assert ErrorResponse.send_body(:unexpected) == "Message could not be sent."
  end
end
