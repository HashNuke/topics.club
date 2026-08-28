defmodule Ircpipe.Chat.DirectMessageSender do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    DirectMessageStore,
    DirectMessageThread,
    Message,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Repo

  def send(
        %ServerConnection{user_id: user_id, id: connection_id},
        thread_id,
        body,
        transmit
      )
      when is_function(transmit, 1) do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot send inside an existing transaction"
    end

    result =
      Repo.transaction(fn ->
        active_connection = ServerConnectionLock.lock_active!(connection_id)

        thread =
          DirectMessageThread
          |> where(
            [thread],
            thread.id == ^thread_id and thread.user_id == ^user_id and
              thread.server_connection_id == ^connection_id
          )
          |> Repo.one()

        cond do
          is_nil(thread) ->
            Repo.rollback(:invalid_direct_message)

          DirectMessageStore.archived?(thread) or not is_nil(thread.closed_at) ->
            Repo.rollback(:direct_message_closed)

          true ->
            case transmit.(thread.peer_nick) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
              error -> Repo.rollback(error)
            end

            maybe_pause_send(thread)

            message =
              %Message{
                user_id: user_id,
                server_connection_id: connection_id,
                direct_message_thread_id: thread.id
              }
              |> Message.changeset(%{
                kind: "message",
                nick: active_connection.nickname,
                hostmask: thread.hostmask,
                metadata: %{
                  "direction" => "outgoing",
                  "peer_nick" => thread.peer_nick,
                  "target" => thread.peer_nick,
                  "account" => thread.account,
                  "hostmask" => thread.hostmask
                },
                body: body,
                mentioned: false,
                occurred_at: DateTime.utc_now(:second)
              })
              |> Repo.insert!()

            Retention.prune(Repo.get!(User, user_id))

            %{thread: thread, message: message}
        end
      end)

    case result do
      {:ok, %{thread: thread, message: message} = recorded} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection_id, fn _active_connection ->
            BufferEvents.direct_message_thread(thread)
            BufferEvents.direct_message(message, thread)
          end)

        {:ok, recorded}

      error ->
        error
    end
  end

  defp maybe_pause_send(thread) do
    case Application.get_env(:topics_club_engine, :pause_direct_message_send) do
      pid when is_pid(pid) ->
        send(pid, {:direct_message_send_paused, self(), thread.id})

        receive do
          {:continue_direct_message_send, thread_id} when thread_id == thread.id -> :ok
        end

      _other ->
        :ok
    end
  end
end
