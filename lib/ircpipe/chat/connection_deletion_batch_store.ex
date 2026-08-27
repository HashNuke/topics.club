defmodule Ircpipe.Chat.ConnectionDeletionBatchStore do
  @moduledoc false

  alias Ircpipe.Chat.{ConnectionDeletionEventBatch, ServerConnection}
  alias Ircpipe.Repo

  def insert!(%ServerConnection{} = connection) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "connection deletion event batches require a database transaction"
    end

    occurred_at = DateTime.utc_now(:second)

    payloads =
      connection
      |> deleted_buffer_payloads()
      |> Enum.map(fn payload ->
        payload
        |> Map.drop([:user_id])
        |> Map.put(:event_id, "connection_deletion:#{connection.id}:#{payload.buffer_id}")
        |> Map.put(:occurred_at, DateTime.to_iso8601(occurred_at))
      end)

    %ConnectionDeletionEventBatch{
      user_id: connection.user_id,
      server_connection_id: connection.id,
      payloads: %{events: payloads}
    }
    |> Repo.insert!()
  end

  defp deleted_buffer_payloads(connection) do
    channel_payloads =
      connection.channel_memberships
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn membership ->
        %{
          user_id: connection.user_id,
          buffer_id: "channel:#{membership.id}",
          server_connection_id: connection.id,
          channel_membership_id: membership.id
        }
      end)

    channel_payloads ++
      [
        %{
          user_id: connection.user_id,
          buffer_id: "server:#{connection.id}",
          server_connection_id: connection.id,
          channel_membership_id: nil
        }
      ]
  end
end
