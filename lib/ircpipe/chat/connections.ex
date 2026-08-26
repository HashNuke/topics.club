defmodule Ircpipe.Chat.Connections do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  def create(%User{} = user, attrs) do
    attrs = attrs |> normalize_host() |> connection_defaults(user)

    %ServerConnection{user_id: user.id}
    |> ServerConnection.changeset(attrs)
    |> Repo.insert()
  end

  def create_or_get(%User{} = user, attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)
    requested_port = Map.get(attrs, "port") || Map.get(attrs, :port) || 6697

    with true <- is_binary(host),
         {:ok, port} when port > 0 and port < 65_536 <-
           Ecto.Type.cast(:integer, requested_port) do
      host = normalize_host_value(host)

      attrs =
        attrs
        |> put_attr(:host, host)
        |> put_attr(:port, port)

      create_or_get_locked(user, attrs, host, port)
    else
      _invalid_endpoint -> create(user, attrs)
    end
  end

  def get!(%User{id: user_id}, id) do
    ServerConnection
    |> where([connection], connection.user_id == ^user_id and connection.id == ^id)
    |> preload(:channel_memberships)
    |> Repo.one!()
  end

  def update(%User{} = user, id, attrs) do
    user
    |> get!(id)
    |> ServerConnection.changeset(normalize_host(attrs))
    |> Repo.update()
  end

  def default_nick(%User{email: email}) do
    base =
      email
      |> String.split("@")
      |> List.first()
      |> String.replace(~r/[^A-Za-z0-9_\-\[\]\\`^{}]/, "_")
      |> String.trim("_-")

    base =
      cond do
        base == "" -> "topics_user"
        String.match?(String.first(base), ~r/^[A-Za-z_\[\]\\`^{}]$/) -> base
        true -> "u_#{base}"
      end

    String.slice(base, 0, 24)
  end

  defp create_or_get_locked(user, attrs, host, port) do
    maybe_wait_for_endpoint_lock(user.id, host, port)

    {:ok, result} =
      Repo.transaction(fn ->
        lock_user!(user.id)

        case find_by_endpoint(user, host, port) do
          %ServerConnection{} = connection ->
            {:ok, connection}

          _missing ->
            maybe_pause_endpoint_create(user.id, host, port)
            create(user, attrs)
        end
      end)

    result
  end

  defp lock_user!(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> select([user], user.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp find_by_endpoint(%User{id: user_id}, host, port) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.port == ^port and
        fragment("lower(btrim(?))", connection.host) == ^host
    )
    |> order_by([connection], asc: connection.inserted_at, asc: connection.id)
    |> limit(1)
    |> Repo.one()
  end

  defp normalize_host(attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)

    if is_binary(host) do
      put_attr(attrs, :host, normalize_host_value(host))
    else
      attrs
    end
  end

  defp normalize_host_value(host) do
    host |> String.trim() |> String.downcase()
  end

  defp maybe_pause_endpoint_create(user_id, host, port) do
    case Application.get_env(:ircpipe, :connection_endpoint_create_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(
          test_pid,
          {:connection_endpoint_create_paused, self(), barrier_ref, user_id, host, port}
        )

        receive do
          {:continue_connection_endpoint_create, ^barrier_ref} -> :ok
        end

      _no_barrier ->
        :ok
    end
  end

  defp maybe_wait_for_endpoint_lock(user_id, host, port) do
    case Application.get_env(:ircpipe, :connection_endpoint_create_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(
          test_pid,
          {:connection_endpoint_lock_ready, self(), barrier_ref, user_id, host, port}
        )

        receive do
          {:start_connection_endpoint_lock, ^barrier_ref} -> :ok
        end

      _no_barrier ->
        :ok
    end
  end

  defp connection_defaults(attrs, user) do
    nickname = present_attr(attrs, :nickname) || default_nick(user)

    attrs
    |> put_attr(:nickname, nickname)
    |> maybe_put_sasl_username(nickname)
  end

  defp maybe_put_sasl_username(attrs, nickname) do
    if present_attr(attrs, :sasl_password) && !present_attr(attrs, :sasl_username) do
      put_attr(attrs, :sasl_username, nickname)
    else
      attrs
    end
  end

  defp present_attr(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    if is_binary(value) && String.trim(value) != "", do: String.trim(value)
  end

  defp put_attr(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.put(attrs, Atom.to_string(key), value)
      Enum.any?(Map.keys(attrs), &is_atom/1) -> Map.put(attrs, key, value)
      true -> Map.put(attrs, Atom.to_string(key), value)
    end
  end
end
