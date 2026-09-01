defmodule TopicsClub.Irc.Session.Initialization do
  @moduledoc false

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.{PendingEchoes, StartupAuthorization, WirekeeperIngestion}

  def initialize(%ServerConnection{} = requested_connection) do
    case StartupAuthorization.load(requested_connection) do
      {%ServerConnection{} = connection, pending_channels} ->
        send(self(), :connect)

        state =
          %{
            connection: connection,
            client: nil,
            client_monitor: nil,
            registered?: false,
            resumed?: false,
            wirekeeper_resume: nil,
            wirekeeper_node_down?: false,
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
            channel_list_request: nil,
            connection_issue: nil,
            preserve_error_status?: false,
            retry_attempt: 0,
            retry_timer: nil
          }

        {:ok, WirekeeperIngestion.initialize(state)}

      nil ->
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end
end
