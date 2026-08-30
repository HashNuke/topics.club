defmodule TopicsClub.Irc.Session.ConnectionIssue do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection

  @terminal_irc_errors %{
    "432" => {"invalid_nickname", "Nickname is not valid", "nickname"},
    "464" => {"authentication_failed", "Authentication failed", "credentials"},
    "465" => {"connection_rejected", "The server rejected this connection", "connection"}
  }

  def from_irc_error(%{code: code} = payload, %ServerConnection{} = connection) do
    case Map.get(@terminal_irc_errors, to_string(code)) do
      {issue_code, title, edit_focus} ->
        issue(issue_code, title, reason(payload), edit_focus,
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
      reason(payload, "Choose another nickname, then reconnect."),
      "nickname",
      attempted_nickname: attempted,
      irc_code: "433"
    )
  end

  def sasl_failure(payload, %ServerConnection{}) do
    issue(
      "authentication_failed",
      "IRC account login failed",
      "Check the IRC account name and password, then reconnect.",
      "credentials",
      irc_code: payload |> Map.get(:code, "") |> to_string()
    )
  end

  def retries_exhausted(reason, %ServerConnection{} = connection) do
    details = technical_details(reason)

    issue(
      "connection_failed",
      "Could not connect after 5 retries",
      "Check the server address, port, TLS setting, or credentials before trying again.",
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

  defp reason(payload, fallback \\ "The IRC server rejected the connection settings.") do
    case Map.get(payload, :reason) do
      reason when is_binary(reason) and reason != "" -> reason
      _missing -> fallback
    end
  end

  defp technical_details(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
  end
end
