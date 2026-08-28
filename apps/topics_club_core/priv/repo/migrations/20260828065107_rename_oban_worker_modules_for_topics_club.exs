defmodule TopicsClub.Repo.Migrations.RenameObanWorkerModulesForTopicsClub do
  use Ecto.Migration

  import Ecto.Query

  @worker_renames [
    {"Ircpipe.Chat.ConnectionDeletionEventsWorker",
     "TopicsClub.Chat.ConnectionDeletionEventsWorker"},
    {"Ircpipe.Chat.ConnectionDeletionReconcilerWorker",
     "TopicsClub.Chat.ConnectionDeletionReconcilerWorker"},
    {"Ircpipe.Chat.ConnectionDeletionWorker", "TopicsClub.Chat.ConnectionDeletionWorker"},
    {"Ircpipe.Chat.NotificationEventsWorker", "TopicsClub.Chat.NotificationEventsWorker"},
    {"Ircpipe.Notifications.PushWorker", "TopicsClub.Notifications.PushWorker"}
  ]

  def change do
    execute(&rename_workers/0, &restore_workers/0)
  end

  defp rename_workers, do: update_workers(@worker_renames)

  defp restore_workers do
    update_workers(
      Enum.map(@worker_renames, fn {old_worker, new_worker} ->
        {new_worker, old_worker}
      end)
    )
  end

  defp update_workers(worker_renames) do
    migration_prefix = prefix()

    Enum.each(worker_renames, fn {old_worker, new_worker} ->
      from(job in "oban_jobs",
        prefix: ^migration_prefix,
        where: job.worker == ^old_worker
      )
      |> repo().update_all(set: [worker: new_worker])
    end)
  end
end
