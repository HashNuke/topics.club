defmodule Ircpipe.BlockedEngineAPI do
  def dispatch(_request) do
    receive do
      :release -> raise "blocked engine API test task must be terminated on timeout"
    end
  end
end
