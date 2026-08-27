defmodule Ircpipe.EngineClientTestAdapter do
  @behaviour Ircpipe.EngineClient.Adapter

  @impl true
  def request(request, timeout) do
    test_pid = Application.fetch_env!(:ircpipe, :engine_client_test_pid)
    send(test_pid, {:engine_client_request, request, timeout})

    case Application.get_env(:ircpipe, :engine_client_test_reply, :ok) do
      :ok -> Ircpipe.EngineClient.Reply.ok(request, %{accepted: true})
      :malformed -> %{status: :ok, data: self()}
      {:error, error} -> Ircpipe.EngineClient.Reply.error(request, error)
    end
  end
end
