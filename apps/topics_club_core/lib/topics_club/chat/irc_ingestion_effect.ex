defmodule TopicsClub.Chat.IrcIngestionEffect do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Query

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Repo

  schema "irc_ingestion_effects" do
    field :wirekeeper_generation, :string
    field :wirekeeper_sequence, :integer
    field :effect_key, :string
    belongs_to :server_connection, ServerConnection

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def claim(%ServerConnection{}, nil), do: :new

  def claim(
        %ServerConnection{} = connection,
        %{
          generation: generation,
          sequence: sequence,
          effect_key: effect_key
        }
      )
      when is_binary(generation) and is_integer(sequence) and sequence > 0 and
             is_binary(effect_key) do
    now = DateTime.utc_now(:second)

    {inserted, _rows} =
      Repo.insert_all(
        __MODULE__,
        [
          %{
            server_connection_id: connection.id,
            wirekeeper_generation: generation,
            wirekeeper_sequence: sequence,
            effect_key: effect_key,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [
          :server_connection_id,
          :wirekeeper_generation,
          :wirekeeper_sequence,
          :effect_key
        ]
      )

    if inserted == 1, do: :new, else: :duplicate
  end

  def claim(%ServerConnection{}, _invalid), do: raise(ArgumentError, "invalid ingestion identity")

  def release(%ServerConnection{id: connection_id}, generation, sequence),
    do: release(connection_id, generation, sequence)

  def release(connection_id, generation, sequence)
      when is_integer(connection_id) and is_binary(generation) and is_integer(sequence) do
    __MODULE__
    |> where(
      [effect],
      effect.server_connection_id == ^connection_id and
        effect.wirekeeper_generation == ^generation and
        effect.wirekeeper_sequence == ^sequence
    )
    |> Repo.delete_all()

    :ok
  end

  def release_many([]), do: :ok

  def release_many(claims) when is_list(claims) do
    filter =
      Enum.reduce(claims, dynamic(false), fn
        {connection_id, generation, sequence}, filter
        when is_integer(connection_id) and is_binary(generation) and is_integer(sequence) ->
          dynamic(
            [effect],
            ^filter or
              (effect.server_connection_id == ^connection_id and
                 effect.wirekeeper_generation == ^generation and
                 effect.wirekeeper_sequence == ^sequence)
          )
      end)

    __MODULE__
    |> where(^filter)
    |> Repo.delete_all()

    :ok
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end
end
