defmodule Ircpipe.Notifications.PushRegistrations do
  import Ecto.Query

  alias Ircpipe.Accounts.{Scope, User, UserToken}

  alias Ircpipe.Notifications.{PushSubscription, PushSubscriptionRateLimit, WebPush}
  alias Ircpipe.Repo

  @max_per_user 5
  @creation_limit 10
  @creation_window_seconds 3_600

  def session_config(%Scope{user: user}, session_token) when is_binary(session_token) do
    installation_id = current_session_installation_id(user.id, session_token)

    %{
      configured: WebPush.configured?(),
      vapid_public_key: WebPush.public_key(),
      session_generation: UserToken.session_token_fingerprint(session_token),
      session_registration_confirmed: is_binary(installation_id),
      session_installation_id: installation_id
    }
  end

  def register(scope, session_token, attrs, user_agent \\ nil)

  def register(%Scope{user: user}, session_token, attrs, user_agent)
      when is_binary(session_token) do
    endpoint = Map.get(attrs, "endpoint") || Map.get(attrs, :endpoint)
    endpoint_hash = endpoint_hash(endpoint)
    installation_id = installation_id(attrs)

    changeset =
      %PushSubscription{user_id: user.id, endpoint_hash: endpoint_hash}
      |> PushSubscription.changeset(Map.put(stringify_keys(attrs), "user_agent", user_agent))

    if changeset.valid? do
      Repo.transaction(fn ->
        lock_user!(user.id)

        user_token =
          lock_session_token(user.id, session_token) || Repo.rollback(:session_expired)

        maybe_pause_registration()

        if Repo.exists?(
             from(subscription in PushSubscription,
               where:
                 subscription.endpoint_hash == ^endpoint_hash and
                   subscription.user_id != ^user.id
             )
           ) do
          Repo.rollback(:endpoint_owned_by_another_account)
        end

        existing =
          PushSubscription
          |> where(
            [subscription],
            subscription.user_id == ^user.id and
              (subscription.endpoint_hash == ^endpoint_hash or
                 subscription.installation_id == ^installation_id)
          )
          |> order_by(
            [subscription],
            desc: subscription.endpoint_hash == ^endpoint_hash,
            desc: subscription.updated_at
          )
          |> limit(1)
          |> Repo.one()

        canonical_installation_id =
          if existing && existing.endpoint_hash == endpoint_hash,
            do: existing.installation_id,
            else: installation_id

        if is_nil(existing) do
          enforce_cap!(user.id)
          record_creation!(user.id)
        end

        from(subscription in PushSubscription,
          where:
            subscription.user_id == ^user.id and
              (subscription.endpoint_hash == ^endpoint_hash or
                 subscription.installation_id == ^installation_id)
        )
        |> Repo.delete_all()

        case changeset
             |> Ecto.Changeset.put_change(:installation_id, canonical_installation_id)
             |> Ecto.Changeset.put_change(:user_token_id, user_token.id)
             |> Repo.insert() do
          {:ok, subscription} -> subscription
          {:error, failed_changeset} -> Repo.rollback(failed_changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  def register(%Scope{}, _session_token, _attrs, _user_agent),
    do: {:error, :session_expired}

  def unregister(%Scope{user: user}, installation_id) do
    from(subscription in PushSubscription,
      where: subscription.user_id == ^user.id and subscription.installation_id == ^installation_id
    )
    |> Repo.delete_all()

    :ok
  end

  defp current_session_installation_id(user_id, session_token) do
    UserToken.valid_session_token_query()
    |> where([token], token.user_id == ^user_id and token.token == ^session_token)
    |> join(:inner, [token], subscription in PushSubscription,
      on: subscription.user_token_id == token.id and subscription.user_id == ^user_id
    )
    |> order_by([_token, subscription], desc: subscription.updated_at)
    |> select([_token, subscription], subscription.installation_id)
    |> limit(1)
    |> Repo.one()
  end

  defp enforce_cap!(user_id) do
    count =
      PushSubscription
      |> where([subscription], subscription.user_id == ^user_id)
      |> Repo.aggregate(:count)

    if count >= @max_per_user, do: Repo.rollback(:too_many_push_subscriptions)
  end

  defp record_creation!(user_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      PushSubscriptionRateLimit,
      [
        %{
          user_id: user_id,
          window_started_at: now,
          creation_count: 0,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_id]
    )

    limit =
      PushSubscriptionRateLimit
      |> where([rate_limit], rate_limit.user_id == ^user_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if DateTime.diff(now, limit.window_started_at, :second) >= @creation_window_seconds do
      limit
      |> Ecto.Changeset.change(window_started_at: now, creation_count: 1)
      |> Repo.update!()
    else
      if limit.creation_count >= @creation_limit do
        Repo.rollback(:push_subscription_rate_limited)
      end

      limit
      |> Ecto.Changeset.change(creation_count: limit.creation_count + 1)
      |> Repo.update!()
    end
  end

  defp lock_user!(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_session_token(user_id, session_token) do
    token =
      UserToken
      |> where(
        [token],
        token.user_id == ^user_id and token.token == ^session_token and
          token.context == "session"
      )
      |> lock("FOR SHARE")
      |> Repo.one()

    if UserToken.session_token_valid?(token), do: token
  end

  defp maybe_pause_registration do
    if test_pid = Application.get_env(:topics_club_gateway, :pause_push_registration) do
      send(test_pid, {:push_registration_paused, self()})

      receive do
        :continue_push_registration -> :ok
      end
    end
  end

  defp endpoint_hash(endpoint) when is_binary(endpoint), do: :crypto.hash(:sha256, endpoint)
  defp endpoint_hash(_endpoint), do: <<>>

  defp installation_id(attrs),
    do: Map.get(attrs, "installation_id") || Map.get(attrs, :installation_id)

  defp stringify_keys(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
