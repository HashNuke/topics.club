defmodule IrcpipeWeb.Api.TopicController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat

  def index(conn, _params) do
    json(conn, %{topics: Enum.map(Chat.list_topics(), &topic_json/1)})
  end

  defp topic_json(topic) do
    %{
      id: topic.id,
      name: topic.name,
      description: topic.description,
      server_host: topic.server_host,
      server_port: topic.server_port,
      use_tls: topic.use_tls,
      channel: topic.channel
    }
  end
end
