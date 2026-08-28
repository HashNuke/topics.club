defmodule Ircpipe.Irc.Session.ClientRegistration do
  @moduledoc false

  @behaviour Ircxd.Client.Adapter

  @impl true
  def init(registry_key) do
    {:ok, _registry} = Registry.register(Ircpipe.Irc.ClientRegistry, registry_key, nil)
    {:ok, nil}
  end

  @impl true
  def handle_event(_event, _context, state), do: {:ok, state}
end
