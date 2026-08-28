defmodule TopicsClub.Irc.CommandResult do
  @moduledoc false

  alias Ircxd.Client.Event

  @display_keys ~w(
    account away channel channels code command description host idle idle_seconds info location mask
    message modes nick realname reason server signon text topic type username version visible
  )a

  def format(%Event{name: name, payload: payload}) do
    %{
      body: format_body(name, payload),
      metadata: %{
        irc_event: Atom.to_string(name),
        irc_payload: structured_fields(payload)
      }
    }
  end

  def format_whois(events) when is_list(events) do
    payloads = Map.new(events, &{&1.name, &1.payload})

    details =
      [
        whois_account(payloads),
        whois_channels(payloads),
        whois_server(payloads),
        whois_secure(payloads),
        whois_idle(payloads)
      ]
      |> Enum.reject(&is_nil/1)

    body =
      case details do
        [] -> "#{whois_identity(payloads)}."
        details -> "#{whois_identity(payloads)}. #{Enum.join(details, "; ")}."
      end

    replies =
      Enum.map(events, fn event ->
        %{
          "event" => Atom.to_string(event.name),
          "payload" => structured_fields(event.payload)
        }
      end)

    %{
      body: body,
      metadata: %{irc_event: "whois_summary", irc_payload: %{"replies" => replies}}
    }
  end

  defp format_body(name, payload) do
    case display_fields(payload) do
      [] -> humanize(name)
      fields -> "#{humanize(name)} — #{Enum.join(fields, ", ")}"
    end
  end

  defp display_fields(payload) when is_map(payload) do
    Enum.flat_map(@display_keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> ["#{key}=#{value}"]
        value when is_integer(value) -> ["#{key}=#{value}"]
        value when is_atom(value) and not is_nil(value) -> ["#{key}=#{value}"]
        value when is_list(value) and value != [] -> ["#{key}=#{Enum.join(value, " ")}"]
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

  defp whois_identity(%{
         whois_user: %{nick: nick, username: username, host: host, realname: realname}
       }) do
    "#{nick} (#{username}@#{host}) — #{realname}"
  end

  defp whois_identity(payloads) do
    Enum.find_value(payloads, "WHOIS result", fn {_name, payload} ->
      if is_map(payload), do: Map.get(payload, :nick)
    end)
  end

  defp whois_account(%{whois_account: %{account: account}}) when is_binary(account),
    do: "Account: #{account}"

  defp whois_account(_payloads), do: nil

  defp whois_channels(%{whois_channels: %{channels: channels}})
       when is_list(channels) and channels != [] do
    "Channels: #{Enum.map_join(channels, ", ", &format_whois_channel/1)}"
  end

  defp whois_channels(_payloads), do: nil

  defp whois_server(%{whois_server: %{server: server, info: info}})
       when is_binary(server) and is_binary(info) do
    if info == "", do: "Server: #{server}", else: "Server: #{server} (#{info})"
  end

  defp whois_server(_payloads), do: nil

  defp whois_secure(%{whois_secure: %{text: text}}) when is_binary(text) do
    details =
      text
      |> String.replace_prefix("is using a secure connection", "")
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    if details == "", do: "Secure connection", else: "Secure: #{details}"
  end

  defp whois_secure(_payloads), do: nil

  defp whois_idle(%{whois_idle: %{idle_seconds: seconds, signon: signon}})
       when is_integer(seconds) and is_integer(signon) do
    "Idle: #{seconds} seconds (connected since #{format_unix_time(signon)})"
  end

  defp whois_idle(_payloads), do: nil

  defp format_whois_channel("@" <> channel), do: "#{channel} (operator)"
  defp format_whois_channel("+" <> channel), do: "#{channel} (voiced)"
  defp format_whois_channel(channel), do: channel

  defp format_unix_time(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
      {:error, _reason} -> Integer.to_string(timestamp)
    end
  end

  defp humanize(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
