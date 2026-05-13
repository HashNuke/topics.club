defmodule IrcpipeWeb.UserSessionHTML do
  use IrcpipeWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:ircpipe, Ircpipe.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
