defmodule IrcpipeWeb.UserChannel.BufferResolver do
  alias Ircpipe.Chat.{Connections, DirectMessageLifecycle, MembershipLookup}
  alias Ircpipe.Irc.Session

  def membership(user, membership_id) do
    membership = MembershipLookup.get!(user, membership_id)

    if membership.status in ["pending", "joined"],
      do: {:ok, membership},
      else: {:error, :invalid_buffer}
  rescue
    _exception in [Ecto.NoResultsError, Ecto.Query.CastError] ->
      {:error, :invalid_buffer}
  end

  def direct_message_thread(user, thread_id) do
    {:ok, DirectMessageLifecycle.get!(user, thread_id)}
  rescue
    _exception in [Ecto.NoResultsError, Ecto.Query.CastError] ->
      {:error, :invalid_direct_message}
  end

  def connection(user, "channel:" <> membership_id) do
    with {:ok, membership} <- membership(user, membership_id) do
      {:ok, membership.server_connection}
    end
  end

  def connection(user, "server:" <> connection_id) do
    {:ok, Connections.get!(user, connection_id)}
  rescue
    _exception in [Ecto.NoResultsError, Ecto.Query.CastError] ->
      {:error, :invalid_server}
  end

  def connection(user, "direct:" <> thread_id) do
    with {:ok, thread} <- direct_message_thread(user, thread_id) do
      {:ok, thread.server_connection}
    end
  end

  def connection(_user, _buffer_id), do: {:error, :invalid_buffer}

  def part_membership(user, "channel:" <> membership_id, []) do
    membership(user, membership_id)
  end

  def part_membership(user, buffer_id, [channel]) do
    with {:ok, connection} <- connection(user, buffer_id) do
      channel_membership(user, connection, channel)
    end
  end

  def part_membership(_user, _buffer_id, _args), do: {:error, :invalid_command_args}

  def channel_membership(user, connection, channel) do
    casemapping =
      case connection_info(connection) do
        {:ok, client_info} -> client_info.casemapping
        {:error, _reason} -> nil
      end

    membership = MembershipLookup.get_by_channel!(user, connection, channel, casemapping)

    if membership.status in ["pending", "joined"],
      do: {:ok, membership},
      else: {:error, :invalid_buffer}
  rescue
    Ecto.NoResultsError -> {:error, :invalid_buffer}
  end

  defp connection_info(connection) do
    Session.connection_info(connection)
  catch
    :exit, _reason -> {:error, :not_connected}
  end
end
