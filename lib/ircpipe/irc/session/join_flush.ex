defmodule Ircpipe.Irc.Session.JoinFlush do
  @moduledoc false

  alias Ircpipe.Irc.Session.JoinLifecycle

  def handle(
        %{join_flush_timer: {_timer, token}, registered?: true} = state,
        token
      ) do
    info = Ircxd.Client.connection_info(state.client)

    state =
      state
      |> Map.put(:client_info, info)
      |> Map.put(:join_validation_ready?, true)
      |> Map.put(:join_flush_timer, nil)
      |> JoinLifecycle.flush()

    {:noreply, state}
  rescue
    Ecto.NoResultsError -> {:stop, :normal, state}
    Ecto.StaleEntryError -> {:stop, :normal, state}
  catch
    :exit, _reason -> {:noreply, %{state | join_flush_timer: nil}}
  end

  def handle(state, _token), do: {:noreply, state}
end
