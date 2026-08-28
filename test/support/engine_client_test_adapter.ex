defmodule Ircpipe.EngineClientTestAdapter do
  @behaviour Ircpipe.EngineClient.Adapter

  @impl true
  def request(request, timeout) do
    test_pid = Application.fetch_env!(:ircpipe, :engine_client_test_pid)
    send(test_pid, {:engine_client_request, request, timeout})

    case Application.get_env(:ircpipe, :engine_client_test_reply, :ok) do
      :ok ->
        Ircpipe.EngineClient.Reply.ok(request, %{accepted: true})

      :malformed ->
        %{status: :ok, data: self()}

      {:error, error} ->
        Ircpipe.EngineClient.Reply.error(request, error)

      {:error, error, details} ->
        Ircpipe.EngineClient.Reply.error(request, error, details)

      {:block_operation, operation} when request.operation == operation ->
        send(test_pid, {:engine_client_blocked, self(), request})

        receive do
          {:release_engine_client, request_id} when request_id == request.request_id ->
            Ircpipe.EngineClient.Reply.ok(request, %{accepted: true})
        end

      {:block_operation, _operation} ->
        Ircpipe.EngineClient.Reply.ok(request, %{accepted: true})
    end
  end
end
