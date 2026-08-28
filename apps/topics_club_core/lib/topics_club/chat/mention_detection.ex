defmodule TopicsClub.Chat.MentionDetection do
  @moduledoc false

  alias Ircxd.Casemapping

  def mentioned?(body, nickname, casemapping)
      when is_binary(body) and is_binary(nickname) and nickname != "" do
    body = Casemapping.normalize(body, casemapping)
    nickname = nickname |> Casemapping.normalize(casemapping) |> Regex.escape()
    nick_character = "A-Za-z0-9_\\-\\[\\]\\\\`^{}|"

    Regex.match?(
      Regex.compile!("(?:^|[^#{nick_character}])#{nickname}(?:$|[^#{nick_character}])", "u"),
      body
    )
  end

  def mentioned?(_body, _nickname, _casemapping), do: false
end
