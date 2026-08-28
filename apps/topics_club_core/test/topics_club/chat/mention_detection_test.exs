defmodule TopicsClub.Chat.MentionDetectionTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.MentionDetection

  test "detects a nickname at message boundaries and next to punctuation" do
    assert MentionDetection.mentioned?("mira", "mira", :ascii)
    assert MentionDetection.mentioned?("hello, mira: ping", "mira", :ascii)
    assert MentionDetection.mentioned?("(MIRA)", "mira", :ascii)
  end

  test "does not detect a nickname embedded in IRC nickname characters" do
    for body <- ["admirable", "mira2", "2mira", "mira_", "mira-", "mira|"] do
      refute MentionDetection.mentioned?(body, "mira", :ascii)
    end
  end

  test "honors the negotiated IRC casemapping" do
    assert MentionDetection.mentioned?("hello {mira}", "[Mira]", :rfc1459)
    refute MentionDetection.mentioned?("hello {mira}", "[Mira]", :ascii)
  end

  test "escapes regex characters in nicknames" do
    assert MentionDetection.mentioned?("ping pipe^nick!", "pipe^nick", :ascii)
    refute MentionDetection.mentioned?("ping pipeXnick!", "pipe^nick", :ascii)
  end

  test "rejects missing message or nickname values" do
    refute MentionDetection.mentioned?(nil, "mira", :ascii)
    refute MentionDetection.mentioned?("hello mira", nil, :ascii)
    refute MentionDetection.mentioned?("hello", "", :ascii)
  end
end
