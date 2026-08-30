defmodule TopicsClubWeb.UserSessionHTML do
  use TopicsClubWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:topics_club_gateway, TopicsClub.Mailer)[:adapter] ==
      Swoosh.Adapters.Local
  end

  defp google_oauth_enabled? do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])
    present?(config[:client_id]) && present?(config[:client_secret])
  end

  defp oauth_enabled? do
    google_oauth_enabled?() || TopicsClubWeb.Auth.DevStrategy.enabled?()
  end

  defp local_auth_enabled? do
    Application.fetch_env!(:topics_club_gateway, :env) in [:dev, :test]
  end

  defp present?(value), do: is_binary(value) && String.trim(value) != ""
end
