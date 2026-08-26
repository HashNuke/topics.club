defmodule IrcpipeWeb.Api.PushSubscriptionController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications

  def create(
        conn,
        %{
          "installation_id" => installation_id,
          "subscription" =>
            %{
              "endpoint" => endpoint,
              "keys" => %{"p256dh" => p256dh, "auth" => auth}
            } = subscription
        }
      ) do
    attrs = %{
      "installation_id" => installation_id,
      "endpoint" => endpoint,
      "p256dh" => p256dh,
      "auth" => auth,
      "expiration_time" => subscription_expiration(subscription)
    }

    case Notifications.upsert_subscription(
           conn.assigns.current_scope,
           attrs,
           get_req_header(conn, "user-agent") |> List.first()
         ) do
      {:ok, stored} ->
        conn
        |> put_session(:push_installation_id, stored.installation_id)
        |> put_status(:created)
        |> json(%{subscription: %{installation_id: stored.installation_id}})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_push_subscription"})

      {:error, :too_many_push_subscriptions} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "too_many_push_subscriptions"})

      {:error, :push_subscription_rate_limited} ->
        conn
        |> put_resp_header("retry-after", "3600")
        |> put_status(:too_many_requests)
        |> json(%{error: "push_subscription_limit_reached"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_push_subscription"})
  end

  def delete(conn, %{"installation_id" => installation_id}) do
    :ok = Notifications.delete_subscription(conn.assigns.current_scope, installation_id)

    conn =
      if get_session(conn, :push_installation_id) == installation_id,
        do: delete_session(conn, :push_installation_id),
        else: conn

    json(conn, %{ok: true})
  end

  defp subscription_expiration(%{"expirationTime" => milliseconds})
       when is_number(milliseconds) do
    case DateTime.from_unix(trunc(milliseconds), :millisecond) do
      {:ok, expiration} -> expiration
      {:error, _reason} -> nil
    end
  end

  defp subscription_expiration(subscription),
    do: Map.get(subscription, "expiration_time")
end
