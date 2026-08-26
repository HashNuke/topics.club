defmodule Ircpipe.ApplicationTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Discovery.Refresher

  test "includes the discovery refresher only when discovery is enabled" do
    assert Ircpipe.Application.discovery_children(true) == [{Refresher, []}]
    assert Ircpipe.Application.discovery_children(false) == []
  end
end
