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

  def pending_generations(cursor \\ nil, limit \\ 100)

  def pending_generations(cursor, limit)
      when (is_nil(cursor) or
              (is_tuple(cursor) and tuple_size(cursor) == 2)) and
             is_integer(limit) and limit > 0 do
    __MODULE__
    |> group_by([effect], [effect.server_connection_id, effect.wirekeeper_generation])
    |> select([effect], %{
      connection_id: effect.server_connection_id,
      generation: effect.wirekeeper_generation
    })
    |> order_by([effect], asc: effect.server_connection_id, asc: effect.wirekeeper_generation)
    |> after_cursor(cursor)
    |> limit(^limit)
    |> Repo.all()
  end

  def release_through(connection_id, generation, sequence)
      when is_integer(connection_id) and is_binary(generation) and is_integer(sequence) and
             sequence >= 0 do
    __MODULE__
    |> where(
      [effect],
      effect.server_connection_id == ^connection_id and
        effect.wirekeeper_generation == ^generation and
        effect.wirekeeper_sequence <= ^sequence
    )
    |> Repo.delete_all()

    :ok
  end

  def release_generation(connection_id, generation)
      when is_integer(connection_id) and is_binary(generation) do
    __MODULE__
    |> where(
      [effect],
      effect.server_connection_id == ^connection_id and
        effect.wirekeeper_generation == ^generation
    )
    |> Repo.delete_all()

    :ok
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {connection_id, generation})
       when is_integer(connection_id) and is_binary(generation) do
    where(
      query,
      [effect],
      effect.server_connection_id > ^connection_id or
        (effect.server_connection_id == ^connection_id and
           effect.wirekeeper_generation > ^generation)
    )
  end
end
