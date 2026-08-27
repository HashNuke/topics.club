defmodule Ircpipe.Irc.Session.ClientLifecycle do
  @moduledoc false

  @stop_timeout 5_000

  def stop(nil), do: :ok

  def stop(client) when is_pid(client) do
    monitor_ref = Process.monitor(client)
    Process.unlink(client)
    Process.exit(client, :shutdown)

    receive do
      {:DOWN, ^monitor_ref, :process, ^client, _reason} -> :ok
    after
      @stop_timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :client_stop_timeout}
    end
  end
end
