defmodule TopicsClub.Irc.Session.RegistrationTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.Registration

  test "tracks ISUPPORT progress even when client info is unavailable" do
    state = %{
      client: nil,
      client_info: :stale,
      isupport_seen?: false,
      registration_boundary_reached?: false
    }

    assert %{client_info: nil, isupport_seen?: true} = Registration.refresh(state, :isupport)
  end

  test "clears stale client info when the IRC client has stopped" do
    client =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, :killed}

    state = %{client: client, client_info: :stale}

    assert %{client_info: nil} = Registration.refresh_client_info(state)
  end

  test "leaves unrelated events unchanged" do
    state = %{client: nil, client_info: :stale}
    assert Registration.refresh(state, :privmsg) == state
  end
end
