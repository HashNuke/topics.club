defmodule Mix.Tasks.Ircpipe.GenCredentialsKeyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints a Base64-encoded 256-bit key" do
    encoded_key =
      capture_io(fn -> Mix.Tasks.Ircpipe.GenCredentialsKey.run([]) end)
      |> String.trim()

    assert {:ok, key} = Base.decode64(encoded_key)
    assert byte_size(key) == 32
  end
end
