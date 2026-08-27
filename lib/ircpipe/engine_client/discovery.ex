defmodule Ircpipe.EngineClient.Discovery do
  @moduledoc false

  @marker_name :ircpipe_engine_marker

  def marker_name, do: @marker_name

  def whereis do
    case :global.whereis_name(@marker_name) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> {:error, :engine_unavailable}
    end
  end

  def engine_node do
    case whereis() do
      {:ok, pid} -> {:ok, node(pid)}
      error -> error
    end
  end
end
