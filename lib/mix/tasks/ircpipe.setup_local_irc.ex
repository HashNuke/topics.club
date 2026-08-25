defmodule Mix.Tasks.Ircpipe.SetupLocalIrc do
  use Mix.Task

  @shortdoc "Creates local development IRC channels from seeded topics"

  @moduledoc """
  Joins the locally seeded topics on InspIRCd so a fresh development setup has
  real IRC channels available for manual testing.

  The task is best-effort. If the local IRC server is not running, setup
  continues after printing a warning.
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    topics = local_topics()

    if topics == [] do
      Mix.shell().info("No local IRC topics found to prepare.")
    else
      prepare_topics(topics)
    end
  end

  defp local_topics do
    Ircpipe.Chat.list_topics()
    |> Enum.filter(&(&1.server_host in ["127.0.0.1", "localhost"] and &1.use_tls == false))
  end

  defp prepare_topics(topics) do
    nick = "topics_setup_#{System.unique_integer([:positive])}"
    first = hd(topics)

    case Ircxd.Client.start_link(
           host: first.server_host,
           port: first.server_port,
           tls: false,
           nick: nick,
           username: "topics_setup",
           realname: "topics.club setup",
           notify: self()
         ) do
      {:ok, client} ->
        with :ok <- wait_registered() do
          Enum.each(topics, &prepare_topic(client, &1))
          Ircxd.Client.quit(client, "setup complete")

          Mix.shell().info(
            "Prepared #{length(topics)} local IRC channels on #{first.server_host}:#{first.server_port}."
          )
        else
          {:error, reason} ->
            Mix.shell().info("Skipping local IRC channel setup: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().info("Skipping local IRC channel setup: #{inspect(reason)}")
    end
  end

  defp wait_registered do
    receive do
      {:ircxd, :registered} -> :ok
      {:ircxd, {:error, reason}} -> {:error, reason}
      {:ircxd, :disconnected} -> {:error, :disconnected}
    after
      10_000 -> {:error, :timeout}
    end
  end

  defp prepare_topic(client, topic) do
    :ok = Ircxd.Client.join(client, topic.channel)
    :ok = Ircxd.Client.topic(client, topic.channel, topic.description)
  catch
    :exit, _reason -> :ok
  end
end
