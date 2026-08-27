defmodule Ircpipe.Irc.Session.Registration do
  @moduledoc false

  alias Ircpipe.Chat.ConnectionCasemapping
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircxd.Client.Info

  def refresh(state, event_name) when event_name in [:isupport, :isupport_batch] do
    state =
      state
      |> refresh_client_info()
      |> Map.put(:isupport_seen?, true)

    if Map.get(state, :registration_boundary_reached?, false) do
      finalize_support(state)
    else
      state
    end
  end

  def refresh(state, event_name) when event_name in [:motd_end, :motd_missing] do
    state
    |> refresh_client_info()
    |> Map.put(:registration_boundary_reached?, true)
    |> finalize_support()
  end

  def refresh(state, event_name)
      when event_name in [
             :registered,
             :welcome,
             :cap_ack,
             :cap_del,
             :cap_nak,
             :cap_new,
             :nick,
             :connected,
             :disconnected,
             :disconnect,
             :reconnecting
           ],
      do: refresh_client_info(state)

  def refresh(state, _event_name), do: state

  def refresh_client_info(%{client: nil} = state), do: Map.put(state, :client_info, nil)

  def refresh_client_info(%{client: client} = state) do
    info = Ircxd.Client.connection_info(client)
    JoinLifecycle.restore(state, info)
  catch
    :exit, _reason -> Map.put(state, :client_info, nil)
  end

  defp persist_casemapping(connection, casemapping) do
    mapping = Atom.to_string(casemapping)

    if connection.casemapping == mapping do
      connection
    else
      case ConnectionCasemapping.update(connection, casemapping) do
        {:ok, updated} ->
          updated

        {:error, _reason} ->
          connection
      end
    end
  end

  defp finalize_support(%{isupport_seen?: true, client_info: %Info{} = info} = state) do
    connection = persist_casemapping(state.connection, info.casemapping)
    mapping = info.casemapping

    state
    |> Map.put(:connection, connection)
    |> Map.put(:active_casemapping, mapping)
    |> JoinLifecycle.rekey(mapping)
    |> Map.put(:isupport_received?, true)
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, JoinLifecycle.cancel_flush(state))
    |> JoinLifecycle.flush()
  end

  defp finalize_support(state) do
    state
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, JoinLifecycle.cancel_flush(state))
    |> JoinLifecycle.flush()
  end
end
