defmodule TopicsClub.Wirekeeper.RejectingDelivery do
  @moduledoc false

  def send(_consumer, _message), do: :nosuspend
end
