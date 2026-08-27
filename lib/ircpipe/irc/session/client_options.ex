defmodule Ircpipe.Irc.Session.ClientOptions do
  @moduledoc false

  alias Ircpipe.Chat.ServerConnection

  @capabilities [
    "server-time",
    "echo-message",
    "multi-prefix",
    "userhost-in-names",
    "message-tags",
    "batch",
    "labeled-response"
  ]

  def build(%ServerConnection{} = connection, notify_pid) when is_pid(notify_pid) do
    [
      host: connection.host,
      port: connection.port,
      tls: connection.use_tls,
      nick: connection.nickname,
      username: connection.username || connection.nickname,
      realname: connection.realname || connection.nickname,
      caps: @capabilities,
      events: :envelope,
      notify: notify_pid
    ]
    |> maybe_put_password(connection.server_password)
    |> maybe_put_sasl(connection.sasl_username, connection.sasl_password)
  end

  defp maybe_put_password(opts, password) do
    if present?(password), do: Keyword.put(opts, :password, password), else: opts
  end

  defp maybe_put_sasl(opts, username, password) do
    if present?(username) and present?(password) do
      Keyword.put(opts, :sasl, {:plain, username, password})
    else
      opts
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
