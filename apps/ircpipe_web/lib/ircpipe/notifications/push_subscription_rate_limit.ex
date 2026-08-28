defmodule Ircpipe.Notifications.PushSubscriptionRateLimit do
  use Ecto.Schema

  alias Ircpipe.Accounts.User

  schema "push_subscription_rate_limits" do
    field :window_started_at, :utc_datetime
    field :creation_count, :integer, default: 0

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
