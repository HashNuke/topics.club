defmodule TopicsClubWeb.UserChannel.ChannelDirectory do
  @moduledoc false

  alias TopicsClub.EngineClient

  def fetch(user, connection) do
    case EngineClient.list_channels(user.id, connection.id) do
      {:ok, %{channels: channels}} ->
        {:ok,
         %{
           server_connection_id: connection.id,
           server_name: connection.name,
           server_host: connection.host,
           channels: channels
         }}

      {:error, %{code: :timeout}} ->
        {:error, :list_timeout}

      {:error, %{code: :invalid_state} = error} ->
        {:error, error}

      {:error, %{code: code}} ->
        {:error, code}
    end
  end
end
