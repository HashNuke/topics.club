defmodule TopicsClub.EngineClientTestAdapter do
  @behaviour TopicsClub.EngineClient.Adapter

  @impl true
  def request(request, timeout) do
    test_pid = Application.fetch_env!(:topics_club_core, :engine_client_test_pid)
    send(test_pid, {:engine_client_request, request, timeout})

    case Application.get_env(:topics_club_core, :engine_client_test_reply, :ok) do
      :ok ->
        TopicsClub.EngineClient.Reply.ok(request, %{accepted: true})

      :malformed ->
        %{status: :ok, data: self()}

      {:error, error} ->
        TopicsClub.EngineClient.Reply.error(request, error)

      {:error, error, details} ->
        TopicsClub.EngineClient.Reply.error(request, error, details)

      {:block_operation, operation} when request.operation == operation ->
        send(test_pid, {:engine_client_blocked, self(), request})

        receive do
          {:release_engine_client, request_id} when request_id == request.request_id ->
            TopicsClub.EngineClient.Reply.ok(request, %{accepted: true})
        end

      {:block_operation, _operation} ->
        TopicsClub.EngineClient.Reply.ok(request, %{accepted: true})
    end
  end
end
