# Ircpipe

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## What this app does

Ircpipe is a web-based IRC client. Users register or sign in, connect to arbitrary IRC networks, join channels, and chat from a React client backed by Phoenix JSON APIs and Phoenix Channels.

The backend persists channel messages for a short configurable window. Each user can choose 1, 2, or 3 days of scrollback. Mention notifications are delivered over the authenticated user socket; the React client shows mention counts in the sidebar while the app is visible and browser notifications while it is in the background.

IRC connections are modeled as one supervised process per user/server connection under `Ircpipe.Irc.SessionSupervisor`.

## Local database

The generated dev/test config expects PostgreSQL on `localhost:5432` with username/password `postgres`/`postgres`. A `docker-compose.yml` is included for that database:

```bash
docker compose up -d postgres
mix setup
mix phx.server
```

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
