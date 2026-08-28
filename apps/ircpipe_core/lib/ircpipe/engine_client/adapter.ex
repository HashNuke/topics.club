defmodule Ircpipe.EngineClient.Adapter do
  @moduledoc false

  @callback request(request :: map(), timeout :: pos_integer()) :: map()
end
