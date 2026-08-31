defmodule TopicsClub.Irc.Session.ClientOptions do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.ClientRegistration

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
      reconnect: false,
      events: :envelope,
      notify: notify_pid,
      adapter: {ClientRegistration, {connection.user_id, connection.id}}
    ]
    |> maybe_put_password(connection.server_password)
    |> maybe_put_sasl(connection.sasl_username, connection.sasl_password)
    |> maybe_put_transport(connection, notify_pid)
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

  defp maybe_put_transport(opts, connection, notify_pid) do
    case Application.get_env(:topics_club_engine, :irc_transport, :direct) do
      :direct ->
        opts

      {:wirekeeper, wirekeeper_node} when is_atom(wirekeeper_node) ->
        adapter_opts = [
          key: connection.id,
          node: wirekeeper_node,
          consumer: notify_pid,
          transport: wirekeeper_transport(connection),
          buffer: Application.get_env(:topics_club_engine, :wirekeeper_buffer, [])
        ]

        opts
        |> Keyword.put(:transport_adapter, {TopicsClub.Irc.WirekeeperTransport, adapter_opts})
        |> maybe_put_resume_binding()

      invalid ->
        raise ArgumentError, "invalid :irc_transport configuration: #{inspect(invalid)}"
    end
  end

  defp wirekeeper_transport(connection) do
    transport = if connection.use_tls, do: :tls, else: :tcp
    {transport, host: connection.host, port: connection.port}
  end

  defp maybe_put_resume_binding(opts) do
    case Application.get_env(:topics_club_engine, :wirekeeper_resume_binding) do
      binding when is_binary(binding) -> Keyword.put(opts, :resume_binding, binding)
      nil -> opts
      invalid -> raise ArgumentError, "invalid :wirekeeper_resume_binding: #{inspect(invalid)}"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
