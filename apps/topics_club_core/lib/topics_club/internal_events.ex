defmodule TopicsClub.InternalEvents do
  @moduledoc false

  require Logger

  alias TopicsClub.InternalEvent

  def emit(type, user_id, data, opts \\ []) do
    with {:ok, event} <- InternalEvent.new(type, user_id, data, opts) do
      publish(event)
    end
  end

  def publish(event) do
    result =
      with :ok <- InternalEvent.validate(event),
           adapter when is_atom(adapter) <-
             Application.get_env(:topics_club_core, :internal_event_adapter),
           true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 1) do
        apply(adapter, :dispatch, [event])
      else
        {:error, _reason} = error -> error
        _unavailable -> {:error, :event_adapter_unavailable}
      end

    log_failure(result, event)
  rescue
    exception ->
      Logger.warning("Internal event adapter raised exception=#{inspect(exception.__struct__)}")
      {:error, :event_adapter_unavailable}
  catch
    :exit, _reason ->
      Logger.warning("Internal event adapter exited")
      {:error, :event_adapter_unavailable}
  end

  defp log_failure({:error, reason} = error, event) do
    Logger.warning(
      "Internal event was not delivered " <>
        "event_type=#{inspect(event_field(event, :type))} " <>
        "event_id=#{inspect(event_field(event, :event_id))} " <>
        "reason=#{inspect(failure_kind(reason))}"
    )

    error
  end

  defp log_failure(result, _event), do: result

  defp failure_kind({:exception, _message}), do: :exception
  defp failure_kind({:exit, _reason}), do: :exit
  defp failure_kind(reason) when is_atom(reason), do: reason
  defp failure_kind(_reason), do: :error

  defp event_field(event, field) when is_map(event), do: Map.get(event, field)
  defp event_field(_event, _field), do: nil
end
