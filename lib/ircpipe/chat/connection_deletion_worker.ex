defmodule Ircpipe.Chat.ConnectionDeletionWorker do
  require Logger

  use Oban.Worker,
    queue: :connection_deletions,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:user_id, :connection_id],
      states: :incomplete
    ]

  alias Ircpipe.Chat.ConnectionDeletion
  alias Ircpipe.Engine.OperationLock

  @retry_interval {1, :minute}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "connection_id" => connection_id}
      }) do
    result =
      OperationLock.run(user_id, connection_id, fn ->
        ConnectionDeletion.resume(user_id, connection_id)
      end)

    case result do
      :ok ->
        :ok

      {:ok, _connection} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Connection deletion failed; snoozing before retry",
          user_id: user_id,
          connection_id: connection_id,
          reason: inspect(reason)
        )

        {:snooze, @retry_interval}
    end
  end
end
