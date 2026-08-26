defmodule Ircpipe.Notifications.SessionBindings do
  import Ecto.Query

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.{Scope, User, UserToken}
  alias Ircpipe.Notifications.PushSubscription
  alias Ircpipe.Repo

  def notification_account(%Scope{user: user}, session_token) when is_binary(session_token) do
    case Accounts.get_user_by_session_token(session_token) do
      {session_user, _inserted_at} when session_user.id == user.id ->
        %{
          user_id: user.id,
          session_generation: UserToken.session_token_fingerprint(session_token)
        }

      _invalid_session ->
        empty_notification_account()
    end
  end

  def notification_account(%Scope{}, _session_token), do: empty_notification_account()
  def notification_account(nil, _session_token), do: empty_notification_account()

  def rotate(%Scope{user: user}, previous_session_token)
      when is_binary(previous_session_token) do
    Repo.transaction(fn ->
      lock_user!(user.id)

      previous =
        UserToken
        |> where(
          [token],
          token.user_id == ^user.id and token.context == "session" and
            token.token == ^previous_session_token
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if UserToken.session_token_valid?(previous) do
        maybe_pause_rotation()
        {next_session_token, next_user_token} = UserToken.build_session_token(user)
        next = Repo.insert!(next_user_token)

        rebound_count =
          from(subscription in PushSubscription,
            where:
              subscription.user_id == ^user.id and
                subscription.user_token_id == ^previous.id
          )
          |> Repo.update_all(set: [user_token_id: next.id])
          |> elem(0)

        Repo.delete!(previous)
        %{session_token: next_session_token, rebound_count: rebound_count}
      else
        Repo.rollback(:invalid_session)
      end
    end)
  end

  def authenticate_and_rotate(email, password, previous_session_token)
      when is_binary(email) and is_binary(password) do
    Repo.transaction(fn ->
      user =
        User
        |> where([candidate], candidate.email == ^email)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if User.valid_password?(user, password) do
        previous = lock_replaceable_session_token(user.id, previous_session_token)
        {next_session_token, next_user_token} = UserToken.build_session_token(user)
        next = Repo.insert!(next_user_token)

        replaced_session_token =
          if previous do
            from(subscription in PushSubscription,
              where:
                subscription.user_id == ^user.id and
                  subscription.user_token_id == ^previous.id
            )
            |> Repo.update_all(set: [user_token_id: next.id])

            Repo.delete!(previous)
            previous_session_token
          end

        %{
          user: user,
          session_token: next_session_token,
          replaced_session_token: replaced_session_token
        }
      else
        Repo.rollback(:invalid_credentials)
      end
    end)
  end

  defp empty_notification_account, do: %{user_id: nil, session_generation: nil}

  defp maybe_pause_rotation do
    if test_pid = Application.get_env(:ircpipe, :pause_session_rotation) do
      send(test_pid, {:session_rotation_paused, self()})

      receive do
        :continue_session_rotation -> :ok
      end
    end
  end

  defp lock_user!(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_replaceable_session_token(user_id, session_token) when is_binary(session_token) do
    UserToken
    |> where(
      [candidate],
      candidate.user_id == ^user_id and candidate.token == ^session_token and
        candidate.context == "session"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_replaceable_session_token(_user_id, _session_token), do: nil
end
