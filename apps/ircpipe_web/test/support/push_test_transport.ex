defmodule Ircpipe.PushTestTransport do
  @moduledoc false
  import Kernel, except: [send: 2]

  def send(subscription, payload) do
    test_pid = Application.fetch_env!(:ircpipe_web, :push_test_pid)

    if Application.get_env(:ircpipe_web, :pause_push_delivery, false) do
      Kernel.send(test_pid, {:push_delivery_paused, self()})

      receive do
        :continue_push_delivery -> :ok
      end
    end

    Kernel.send(test_pid, {:push_sent, subscription, payload})
    Application.get_env(:ircpipe_web, :push_test_result, :ok)
  end
end
