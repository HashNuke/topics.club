defmodule Ircpipe.Chat.Retention do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.Message
  alias Ircpipe.Repo

  def update_days(%User{} = user, days) do
    days = days |> to_int(3) |> min(3) |> max(1)

    user
    |> Ecto.Changeset.change(message_retention_days: days)
    |> Repo.update()
  end

  def prune(%User{} = user, now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -user.message_retention_days, :day)

    Message
    |> where([message], message.user_id == ^user.id and message.occurred_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp to_int(_value, default), do: default
end
