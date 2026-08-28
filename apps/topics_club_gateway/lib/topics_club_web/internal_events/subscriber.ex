defmodule TopicsClubWeb.InternalEvents.Subscriber do
  @moduledoc false

  use GenServer

  require Logger

  alias TopicsClub.InternalEvent
  alias TopicsClub.InternalEvents.PubSubAdapter

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, PubSubAdapter.topic())

    {:ok, %{adapter: Keyword.get(opts, :adapter, TopicsClubWeb.InternalEvents.Adapter)}}
  end

  @impl true
  def handle_info({PubSubAdapter, event}, state) do
    result = deliver(state.adapter, event)
    emit_delivery_telemetry(result, event)

    if not delivered?(result) do
      Logger.warning(
        "Cluster internal event was not delivered " <>
          "event_id=#{inspect(event_field(event, :event_id))} " <>
          "event_type=#{inspect(event_field(event, :type))} " <>
          "result=#{inspect(failure_kind(result))}"
      )
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(adapter, event) do
    with :ok <- InternalEvent.validate(event),
         true <- is_atom(adapter) and Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :dispatch, 1) do
      apply(adapter, :dispatch, [event])
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :event_adapter_unavailable}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp emit_delivery_telemetry(result, event) do
    :telemetry.execute(
      [:topics_club, :internal_event, :cluster_delivery],
      %{system_time: System.system_time()},
      %{
        event_id: event_field(event, :event_id),
        event_type: event_field(event, :type),
        result: if(delivered?(result), do: :ok, else: :error)
      }
    )
  end

  defp delivered?(:ok), do: true
  defp delivered?({:ok, _value}), do: true
  defp delivered?(_result), do: false

  defp failure_kind({:error, {:exception, _message}}), do: :exception
  defp failure_kind({:error, {:exit, _reason}}), do: :exit
  defp failure_kind({:error, reason}) when is_atom(reason), do: reason
  defp failure_kind(_result), do: :error

  defp event_field(event, key) when is_map(event), do: Map.get(event, key)
  defp event_field(_event, _key), do: nil
end
