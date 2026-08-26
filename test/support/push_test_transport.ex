defmodule Ircpipe.PushTestTransport do
  @moduledoc false
  import Kernel, except: [send: 2]

  def send(subscription, payload) do
    test_pid = Application.fetch_env!(:ircpipe, :push_test_pid)
    Kernel.send(test_pid, {:push_sent, subscription, payload})
    Application.get_env(:ircpipe, :push_test_result, :ok)
  end
end
