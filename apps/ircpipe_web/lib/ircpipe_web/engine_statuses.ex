defmodule IrcpipeWeb.EngineStatuses do
  @moduledoc false

  alias Ircpipe.Accounts.User
  alias Ircpipe.EngineClient

  def fetch(%User{id: user_id}, connections) when is_list(connections) do
    connection_ids = Enum.map(connections, & &1.id)

    case EngineClient.connection_statuses(user_id, connection_ids) do
      {:ok, %{statuses: statuses}} ->
        Map.new(statuses, &{&1.connection_id, &1.status})

      {:error, _reason} ->
        Map.new(connection_ids, &{&1, "disconnected"})
    end
  end

  def get(statuses, connection), do: Map.get(statuses, connection.id, "disconnected")

  def one(%User{} = user, connection) do
    user
    |> fetch([connection])
    |> get(connection)
  end
end
