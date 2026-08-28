defmodule TopicsClub.Irc.EventFormatting do
  @moduledoc false

  alias Ircxd.ISupport

  def action_body({:ok, %{command: "ACTION", params: params}}), do: {:ok, params}
  def action_body(_ctcp), do: :error

  def sender_metadata(payload) do
    %{
      account: Map.get(payload, :account),
      hostmask: Map.get(payload, :raw_source),
      sender_role: role_from_prefixes(Map.get(payload, :prefixes, []))
    }
  end

  def mode_presence_diffs(%{modes: modes, params: params}, isupport) when is_map(isupport) do
    modes
    |> String.graphemes()
    |> Enum.reduce({"+", params, []}, fn
      sign, {_current_sign, remaining_params, diffs} when sign in ["+", "-"] ->
        {sign, remaining_params, diffs}

      mode, {sign, remaining_params, diffs} ->
        {nick, next_params} =
          if mode_argument?(isupport, mode, sign) do
            {List.first(remaining_params), Enum.drop(remaining_params, 1)}
          else
            {nil, remaining_params}
          end

        role = role_for_mode(isupport, mode)

        diff =
          if is_binary(role) && is_binary(nick) do
            %{
              action: "role",
              nick: nick,
              role: if(sign == "+", do: role, else: "user")
            }
          end

        {sign, next_params, maybe_append(diffs, diff)}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  def mode_presence_diffs(_payload, _isupport), do: []

  def service_name(nick) when is_binary(nick) do
    if String.ends_with?(nick, "Serv"), do: nick
  end

  def service_name(_nick), do: nil

  def mode_body(payload) do
    setter = if present?(Map.get(payload, :nick)), do: Map.get(payload, :nick), else: "server"
    modes = Map.get(payload, :modes)
    rendered_params = Enum.join(Map.get(payload, :params, []), " ")

    mode_text =
      if present?(rendered_params) do
        "#{modes} #{rendered_params}"
      else
        modes
      end

    "#{setter} set mode #{mode_text}."
  end

  def kick_body(%{nick: nick, target_nick: target_nick, reason: reason}) do
    kicker = if present?(nick), do: nick, else: "server"

    if present?(reason) do
      "#{target_nick} was kicked by #{kicker}: #{reason}"
    else
      "#{target_nick} was kicked by #{kicker}."
    end
  end

  defp role_from_prefixes(prefixes) when is_list(prefixes) do
    cond do
      "~" in prefixes -> "owner"
      "&" in prefixes -> "admin"
      "@" in prefixes -> "op"
      "%" in prefixes -> "halfop"
      "+" in prefixes -> "voice"
      true -> nil
    end
  end

  defp role_from_prefixes(_prefixes), do: nil

  defp mode_argument?(isupport, mode, sign) do
    case ISupport.channel_mode_type(isupport, mode) do
      type when type in [:list, :always_arg] -> true
      :set_arg -> sign == "+"
      _never_or_unknown -> false
    end
  end

  defp role_for_mode(isupport, mode) do
    case ISupport.prefix_for_mode(isupport, mode) do
      "~" -> "owner"
      "&" -> "admin"
      "@" -> "op"
      "%" -> "halfop"
      "+" -> "voice"
      _unknown -> nil
    end
  end

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: [item | list]

  defp present?(value), do: is_binary(value) and value != ""
end
