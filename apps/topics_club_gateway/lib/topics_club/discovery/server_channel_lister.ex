defmodule TopicsClub.Discovery.ServerChannelLister do
  alias TopicsClub.Discovery.Network
  alias Ircxd.Client

  @default_timeout :timer.minutes(5)

  def fetch(%Network{} = network, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    owner = self()
    token = make_ref()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(owner, {token, do_fetch(network, timeout)})
      end)

    monitor = Process.monitor(pid)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout + 1_000 ->
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp do_fetch(network, timeout) do
    nick = "tc#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    opts = [
      host: network.host,
      port: network.port,
      tls: network.use_tls,
      nick: nick,
      username: nick,
      realname: "topics.club directory",
      notify: self()
    ]

    case Client.start_link(opts) do
      {:ok, client} ->
        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          await_registration(client, deadline)
        after
          if Process.alive?(client), do: GenServer.stop(client, :normal)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_registration(client, deadline) do
    receive do
      {:ircxd, :registered} ->
        case Client.list(client) do
          :ok -> collect_channels(client, deadline, %{})
          error -> error
        end

      {:ircxd, {:connect_error, reason}} ->
        {:error, reason}

      {:ircxd, :disconnected} ->
        {:error, :disconnected}

      {:EXIT, ^client, reason} ->
        {:error, reason}

      _event ->
        await_registration(client, deadline)
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp collect_channels(client, deadline, channels) do
    receive do
      {:ircxd, {:list_entry, %{channel: name} = payload}} ->
        channel = %{
          name: name,
          topic: Map.get(payload, :topic),
          user_count: parse_count(Map.get(payload, :visible))
        }

        collect_channels(client, deadline, Map.put(channels, name, channel))

      {:ircxd, {:list_end, _payload}} ->
        {:ok,
         channels
         |> Map.values()
         |> Enum.sort_by(fn channel -> {-channel.user_count, String.downcase(channel.name)} end)}

      {:ircxd, :disconnected} ->
        {:error, :disconnected}

      {:EXIT, ^client, reason} ->
        {:error, reason}

      _event ->
        collect_channels(client, deadline, channels)
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp parse_count(value) when is_integer(value), do: value

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _error -> 0
    end
  end

  defp parse_count(_value), do: 0
end
