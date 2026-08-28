defmodule TopicsClub.Chat.PeerIdentity do
  @moduledoc false

  alias TopicsClub.Chat.DirectMessageThread

  def details(metadata) do
    account = metadata |> value(:account) |> normalize_account()
    hostmask = metadata |> value(:hostmask) |> normalize_text()

    %{
      account: account,
      hostmask: hostmask,
      primary_key: identity(account, hostmask),
      keys: keys(account, hostmask)
    }
  end

  def keys(metadata), do: details(metadata).keys

  def thread_keys(%DirectMessageThread{} = thread) do
    thread.account
    |> keys(thread.hostmask)
    |> then(fn keys ->
      if thread.identity_key, do: Enum.uniq([thread.identity_key | keys]), else: keys
    end)
  end

  defp normalize_account(account) when is_binary(account) do
    case String.trim(account) do
      account when account in ["", "*"] -> nil
      account -> account
    end
  end

  defp normalize_account(_account), do: nil

  defp normalize_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_text), do: nil

  defp identity(account, _hostmask) when is_binary(account),
    do: "account:#{String.downcase(account)}"

  defp identity(nil, hostmask) when is_binary(hostmask) do
    stable_hostmask =
      case String.split(hostmask, "!", parts: 2) do
        [_nick, user_host] -> user_host
        [source] -> source
      end

    "hostmask:#{String.downcase(stable_hostmask)}"
  end

  defp identity(nil, nil), do: nil

  defp keys(account, hostmask) do
    [identity(account, nil), identity(nil, hostmask)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
