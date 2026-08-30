defmodule TopicsClub.Irc.Session.ConnectionIssue do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection

  @terminal_irc_errors %{
    "432" =>
      {"invalid_nickname", "Nickname is not valid",
       "Use a random nickname and reconnect now, or edit the connection to choose one yourself.",
       "nickname"},
    "464" =>
      {"authentication_failed", "Authentication failed",
       "Check the IRC account password. If the account name is wrong, add a new connection.",
       "credentials"},
    "465" =>
      {"connection_rejected", "The server rejected this connection",
       "Review the port, TLS setting, or credentials, then save to reconnect.", "connection"}
  }

  def from_irc_error(%{code: code}, %ServerConnection{} = connection) do
    case Map.get(@terminal_irc_errors, to_string(code)) do
      {issue_code, title, summary, edit_focus} ->
        issue(issue_code, title, summary, edit_focus,
          attempted_nickname: connection.nickname,
          irc_code: to_string(code)
        )

      nil ->
        nil
    end
  end

  def from_irc_error(_payload, %ServerConnection{}), do: nil

  def nickname_in_use(payload, %ServerConnection{} = connection) do
    attempted = Map.get(payload, :attempted) || connection.nickname

    issue(
      "nickname_in_use",
      "Nickname is already in use",
      "Use a random nickname and reconnect now, or edit the connection to choose one yourself.",
      "nickname",
      attempted_nickname: attempted,
      irc_code: "433"
    )
  end

  def sasl_failure(payload, %ServerConnection{}) do
    issue(
      "authentication_failed",
      "IRC account login failed",
      "Check the IRC account password. If the account name is wrong, add a new connection.",
      "credentials",
      irc_code: payload |> Map.get(:code, "") |> to_string()
    )
  end

  def retries_exhausted(reason, %ServerConnection{} = connection) do
    details = technical_details(reason)

    issue(
      "connection_failed",
      "Could not connect after 5 retries",
      "Check the port, TLS setting, or passwords. If the server or IRC account is wrong, add a new connection.",
      "connection",
      host: connection.host,
      port: connection.port,
      technical_details: details
    )
  end

  defp issue(code, title, summary, edit_focus, details) do
    details
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
    |> Map.merge(%{
      code: code,
      title: title,
      summary: summary,
      edit_focus: edit_focus
    })
  end

  defp technical_details(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
  end
end
