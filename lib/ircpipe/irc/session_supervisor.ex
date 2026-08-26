defmodule Ircpipe.Irc.SessionSupervisor do
  use DynamicSupervisor

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.Session

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(%ServerConnection{} = connection) do
    spec = {Session, connection}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def stop_session(%ServerConnection{} = connection, reason \\ "leaving") do
    case Registry.lookup(Ircpipe.Irc.SessionRegistry, {connection.user_id, connection.id}) do
      [{_pid, _value}] ->
        case Session.quit(connection, reason) do
          :ok -> :ok
          {:error, :closed} -> :ok
          error -> error
        end

      [] ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
