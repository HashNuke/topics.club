defmodule Ircpipe.InternalEvents do
  @moduledoc false

  alias Ircpipe.InternalEvent

  def emit(type, user_id, data, opts \\ []) do
    with {:ok, event} <- InternalEvent.new(type, user_id, data, opts) do
      publish(event)
    end
  end

  def publish(event) do
    with :ok <- InternalEvent.validate(event),
         adapter when is_atom(adapter) <- Application.get_env(:ircpipe, :internal_event_adapter),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 1) do
      apply(adapter, :dispatch, [event])
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :event_adapter_unavailable}
    end
  rescue
    _exception -> {:error, :event_adapter_unavailable}
  catch
    :exit, _reason -> {:error, :event_adapter_unavailable}
  end
end
