defmodule TopicsClubWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channels.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint TopicsClubWeb.Endpoint

      use TopicsClubWeb, :verified_routes

      import Phoenix.ChannelTest
      import TopicsClubWeb.ChannelCase
    end
  end

  setup tags do
    TopicsClubWeb.DataCase.setup_sandbox(tags)
    :ok
  end
end
