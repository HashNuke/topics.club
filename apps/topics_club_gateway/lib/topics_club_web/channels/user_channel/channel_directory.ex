defmodule TopicsClubWeb.UserChannel.ChannelDirectory do
  @moduledoc false

  alias TopicsClub.EngineClient

  def fetch(user, connection, params \\ %{}) do
    query = Map.get(params, "query", "")
    page = Map.get(params, "page", 1)

    case EngineClient.list_channels(user.id, connection.id, query: query, page: page) do
      {:ok, directory} ->
        {:ok,
         Map.merge(directory, %{
           server_connection_id: connection.id,
           server_name: connection.name,
           server_host: connection.host
         })}

      {:error, %{code: :timeout}} ->
        {:error, :list_timeout}

      {:error, %{code: :invalid_state} = error} ->
        {:error, error}

      {:error, %{code: code}} ->
        {:error, code}
    end
  end
end
