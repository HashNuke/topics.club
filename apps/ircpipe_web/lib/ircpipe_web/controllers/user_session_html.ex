defmodule IrcpipeWeb.UserSessionHTML do
  use IrcpipeWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:ircpipe_web, Ircpipe.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  defp google_oauth_enabled? do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])
    present?(config[:client_id]) && present?(config[:client_secret])
  end

  defp oauth_enabled? do
    google_oauth_enabled?() || IrcpipeWeb.Auth.DevStrategy.enabled?()
  end

  defp present?(value), do: is_binary(value) && String.trim(value) != ""
end
