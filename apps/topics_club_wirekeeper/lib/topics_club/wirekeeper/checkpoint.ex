defmodule TopicsClub.Wirekeeper.Checkpoint do
  @moduledoc false

  @type value ::
          nil
          | boolean()
          | number()
          | atom()
          | binary()
          | [value()]
          | %{optional(atom() | binary() | integer()) => value()}

  @type t :: %{optional(atom() | binary() | integer()) => value()}

  @spec encode(term(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_checkpoint | :checkpoint_too_large}
  def encode(checkpoint, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    cond do
      not valid_map?(checkpoint) ->
        {:error, :invalid_checkpoint}

      :erlang.external_size(checkpoint) > max_bytes ->
        {:error, :checkpoint_too_large}

      true ->
        encoded = :erlang.term_to_binary(checkpoint)

        if byte_size(encoded) <= max_bytes do
          {:ok, encoded}
        else
          {:error, :checkpoint_too_large}
        end
    end
  end

  @spec decode(nil | binary()) :: nil | t()
  def decode(nil), do: nil
  def decode(encoded) when is_binary(encoded), do: :erlang.binary_to_term(encoded)

  defp valid_value?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value) or
              is_binary(value),
       do: true

  defp valid_value?(value) when is_list(value), do: valid_list?(value)
  defp valid_value?(value) when is_map(value), do: valid_map?(value)
  defp valid_value?(_value), do: false

  defp valid_list?([]), do: true
  defp valid_list?([head | tail]), do: valid_value?(head) and valid_list?(tail)
  defp valid_list?(_improper_tail), do: false

  defp valid_map?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested_value} ->
      valid_key?(key) and valid_value?(nested_value)
    end)
  end

  defp valid_map?(_value), do: false

  defp valid_key?(key), do: is_atom(key) or is_binary(key) or is_integer(key)
end
