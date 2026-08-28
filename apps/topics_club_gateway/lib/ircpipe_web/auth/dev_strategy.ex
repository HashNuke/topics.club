defmodule IrcpipeWeb.Auth.DevStrategy do
  use Ueberauth.Strategy, ignores_csrf_attack: true

  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Auth.Info

  @impl true
  def handle_request!(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, form())
    |> halt()
  end

  @impl true
  def uid(conn), do: email(conn)

  @impl true
  def info(conn) do
    %Info{
      email: email(conn),
      name: param(conn, "name") || email(conn)
    }
  end

  @impl true
  def credentials(_conn), do: %Credentials{}

  @impl true
  def extra(conn), do: %Extra{raw_info: conn.params}

  def enabled? do
    providers = Application.get_env(:ueberauth, Ueberauth)[:providers] || []

    Keyword.has_key?(providers, :developer) ||
      Application.get_env(:topics_club_gateway, :dev_routes) == true
  end

  defp email(conn), do: param(conn, "email")

  defp param(conn, key) do
    get_in(conn.params, ["developer", key]) || conn.params[key]
  end

  defp form do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Ircpipe developer sign in</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: system-ui, sans-serif; background: #fafaf9; color: #18181b; }
          form { width: min(420px, calc(100vw - 32px)); display: grid; gap: 14px; }
          h1 { margin: 0 0 8px; font-size: 28px; }
          label { display: grid; gap: 6px; font-size: 14px; font-weight: 600; }
          input { border: 1px solid #d4d4d8; border-radius: 6px; padding: 11px 12px; font: inherit; }
          button { border: 0; border-radius: 6px; padding: 12px; background: #18181b; color: white; font: inherit; font-weight: 700; cursor: pointer; }
        </style>
      </head>
      <body>
        <form method="get" action="/auth/developer/callback">
          <h1>Ircpipe developer sign in</h1>
          <label>Name <input name="developer[name]" value="Dev User" required></label>
          <label>Email <input name="developer[email]" type="email" value="dev@example.test" required></label>
          <button>Sign in</button>
        </form>
      </body>
    </html>
    """
  end
end
