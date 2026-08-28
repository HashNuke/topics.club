defmodule TopicsClub.Chat.ConnectionAttributes do
  @moduledoc false

  alias TopicsClub.Accounts.User

  def prepare(attrs, %User{} = user) do
    attrs
    |> normalize_host()
    |> put_defaults(user)
  end

  def normalize_host(attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)

    if is_binary(host) do
      put(attrs, :host, normalize_host_value(host))
    else
      attrs
    end
  end

  def normalize_host_value(host) do
    host |> String.trim() |> String.downcase()
  end

  def default_nick(%User{email: email}) do
    base =
      email
      |> String.split("@")
      |> List.first()
      |> String.replace(~r/[^A-Za-z0-9_\-\[\]\\`^{}]/, "_")
      |> String.trim("_-")

    base =
      cond do
        base == "" -> "topics_user"
        String.match?(String.first(base), ~r/^[A-Za-z_\[\]\\`^{}]$/) -> base
        true -> "u_#{base}"
      end

    String.slice(base, 0, 24)
  end

  def put(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.put(attrs, Atom.to_string(key), value)
      Enum.any?(Map.keys(attrs), &is_atom/1) -> Map.put(attrs, key, value)
      true -> Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp put_defaults(attrs, user) do
    nickname = present(attrs, :nickname) || default_nick(user)

    attrs
    |> put(:nickname, nickname)
    |> maybe_put_sasl_username(nickname)
  end

  defp maybe_put_sasl_username(attrs, nickname) do
    if present(attrs, :sasl_password) && !present(attrs, :sasl_username) do
      put(attrs, :sasl_username, nickname)
    else
      attrs
    end
  end

  defp present(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    if is_binary(value) && String.trim(value) != "", do: String.trim(value)
  end
end
