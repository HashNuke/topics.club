defmodule TopicsClub.Irc.Session.Initialization do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.{PendingEchoes, StartupAuthorization}

  def initialize(%ServerConnection{} = requested_connection) do
    case StartupAuthorization.load(requested_connection) do
      {%ServerConnection{} = connection, pending_channels} ->
        send(self(), :connect)

        {:ok,
         %{
           connection: connection,
           client: nil,
           registered?: false,
           pending_joins: pending_channels,
           joined_channels: MapSet.new(),
           names_buffers: %{},
           pending_echoes: PendingEchoes.new(),
           pending_commands: %{},
           ignored_event_logs: %{},
           client_info: nil,
           isupport_received?: false,
           isupport_seen?: false,
           registration_boundary_reached?: false,
           join_validation_ready?: false,
           joins_flushed?: false,
           join_flush_timer: nil,
           sent_joins: MapSet.new(),
           channel_list_request: nil
         }}

      nil ->
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end
end
