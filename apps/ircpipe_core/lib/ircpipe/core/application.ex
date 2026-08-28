defmodule Ircpipe.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Ircpipe.CoreSupervisor.start_link([])
  end
end
