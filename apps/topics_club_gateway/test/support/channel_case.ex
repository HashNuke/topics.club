defmodule IrcpipeWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channels.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint IrcpipeWeb.Endpoint

      use IrcpipeWeb, :verified_routes

      import Phoenix.ChannelTest
      import IrcpipeWeb.ChannelCase
    end
  end

  setup tags do
    IrcpipeWeb.DataCase.setup_sandbox(tags)
    :ok
  end
end
