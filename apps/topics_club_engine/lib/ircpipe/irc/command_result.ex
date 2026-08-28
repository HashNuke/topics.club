defmodule Ircpipe.Irc.CommandResult do
  @moduledoc false

  alias Ircxd.Client.Event

  @display_keys ~w(
    account away channel channels code command description host idle location mask nick realname
    reason server text topic type username version visible
  )a

  def format(%Event{name: name, payload: payload}) do
    fields = display_fields(payload)

    body =
      case fields do
        [] -> humanize(name)
        fields -> "#{humanize(name)} — #{Enum.join(fields, ", ")}"
      end

    %{
      body: body,
      metadata: %{
        irc_event: Atom.to_string(name),
        irc_payload: structured_fields(payload)
      }
    }
  end

  defp display_fields(payload) when is_map(payload) do
    Enum.flat_map(@display_keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> ["#{key}=#{value}"]
        value when is_integer(value) -> ["#{key}=#{value}"]
        value when is_atom(value) -> ["#{key}=#{value}"]
        _value -> []
      end
    end)
  end

  defp display_fields(payload) when is_binary(payload), do: [payload]
  defp display_fields(_payload), do: []

  defp structured_fields(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), safe_value(value)} end)
    |> Map.take(Enum.map(@display_keys, &Atom.to_string/1))
  end

  defp structured_fields(payload) when is_binary(payload), do: %{"text" => payload}
  defp structured_fields(_payload), do: %{}

  defp safe_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_value(values) when is_list(values), do: Enum.map(values, &safe_value/1)
  defp safe_value(_value), do: nil

  defp humanize(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
