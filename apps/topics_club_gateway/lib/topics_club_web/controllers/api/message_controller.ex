defmodule TopicsClubWeb.Api.MessageController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Chat.MessageHistory
  alias TopicsClub.Realtime.Event

  def buffer_index(conn, %{"buffer_id" => buffer_id} = params) do
    user = conn.assigns.current_scope.user

    messages =
      case Map.get(params, "command_ids") do
        command_ids when is_binary(command_ids) ->
          MessageHistory.list_buffer_command_messages(
            user,
            buffer_id,
            String.split(command_ids, ",")
          )

        _command_ids ->
          MessageHistory.list_buffer_messages(user, buffer_id,
            limit: Map.get(params, "limit", 150),
            before: Map.get(params, "before"),
            after: Map.get(params, "after")
          )
      end

    json(conn, %{messages: Enum.map(messages, &message_json(&1, buffer_id))})
  end

  defp message_json(message, buffer_id) do
    Event.message(message, buffer_id)
  end
end
