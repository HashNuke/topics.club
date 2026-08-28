defmodule TopicsClub.InternalEvent.Adapter do
  @moduledoc false

  @callback dispatch(event :: map()) :: :ok | {:ok, term()} | {:error, term()}
end
