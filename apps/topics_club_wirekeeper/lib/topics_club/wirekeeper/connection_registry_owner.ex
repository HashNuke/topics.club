defmodule TopicsClub.Wirekeeper.ConnectionRegistryOwner do
  @moduledoc false

  use GenServer

  @registry TopicsClub.Wirekeeper.ConnectionRegistry
  @start_attempts 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case start_registry(@start_attempts) do
      {:ok, registry} -> {:ok, %{registry: registry}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, registry, reason}, %{registry: registry} = state) do
    {:stop, {:shutdown, {:registry_stopped, reason}}, state}
  end

  def handle_info({:EXIT, _failed_start, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp start_registry(0), do: {:error, :registry_start_timeout}

  defp start_registry(attempts) do
    case Registry.start_link(keys: :unique, partitions: 1, name: @registry) do
      {:ok, registry} ->
        {:ok, registry}

      {:error, {:already_started, _registry}} ->
        retry_registry_start(attempts)

      {:error, {:shutdown, _reason}} ->
        retry_registry_start(attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_registry_start(attempts) do
    receive do
    after
      1 -> start_registry(attempts - 1)
    end
  end
end
