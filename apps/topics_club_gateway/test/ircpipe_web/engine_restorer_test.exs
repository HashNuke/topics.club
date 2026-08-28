defmodule IrcpipeWeb.EngineRestorerTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection
  alias IrcpipeWeb.EngineRestorer

  setup do
    previous_adapter = Application.get_env(:topics_club_core, :engine_client_adapter)
    previous_test_pid = Application.get_env(:topics_club_core, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:topics_club_core, :engine_client_test_reply)

    Application.put_env(
      :topics_club_core,
      :engine_client_adapter,
      IrcpipeWeb.EngineClientTestAdapter
    )

    Application.put_env(:topics_club_core, :engine_client_test_pid, self())

    Application.put_env(
      :topics_club_core,
      :engine_client_test_reply,
      {:block_operation, :ensure_connection}
    )

    on_exit(fn ->
      restore_env(:engine_client_adapter, previous_adapter)
      restore_env(:engine_client_test_pid, previous_test_pid)
      restore_env(:engine_client_test_reply, previous_test_reply)
    end)

    restorer = start_supervised!({EngineRestorer, name: nil})
    %{restorer: restorer}
  end

  test "coalesces concurrent restores behind one globally bounded worker pool", %{
    restorer: restorer
  } do
    user = %User{id: 42}

    connections =
      Enum.map(1..10, fn id ->
        %ServerConnection{id: id, user_id: user.id, desired_state: "connected"}
      end)

    callers =
      Enum.map(1..5, fn _index ->
        Task.async(fn -> EngineRestorer.restore(restorer, user, connections) end)
      end)

    assert Enum.map(callers, &Task.await/1) == List.duplicate(:ok, 5)

    first_wave =
      Enum.map(1..8, fn _index ->
        assert_receive {:engine_client_blocked, worker, request}
        {worker, request}
      end)

    refute_receive {:engine_client_blocked, _worker, _request}, 100
    Enum.each(first_wave, &release/1)

    second_wave =
      Enum.map(1..2, fn _index ->
        assert_receive {:engine_client_blocked, worker, request}
        {worker, request}
      end)

    Enum.each(second_wave, &release/1)
    assert :ok = EngineRestorer.await_idle(restorer, 1_000)

    refute_receive {:engine_client_blocked, _worker, _request}, 100
  end

  defp release({worker, request}) do
    send(worker, {:release_engine_client, request.request_id})
  end

  defp restore_env(key, nil), do: Application.delete_env(:topics_club_core, key)
  defp restore_env(key, value), do: Application.put_env(:topics_club_core, key, value)
end
