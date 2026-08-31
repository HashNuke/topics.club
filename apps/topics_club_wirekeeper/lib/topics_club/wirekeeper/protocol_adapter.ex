defmodule TopicsClub.Wirekeeper.ProtocolAdapter do
  @moduledoc """
  Customizes how a kept connection handles inbound bytes.

  An adapter may preserve framing state, forward application data to the attached consumer, and
  write protocol maintenance replies directly to the upstream connection. Adapter callbacks run
  inside one connection process and must not block or perform their own socket ownership.
  """

  @type state :: map()
  @type action :: {:forward, binary()} | {:reply, iodata()}
  @type error_reason :: atom() | {:adapter_error, atom()}

  @doc "Initializes protocol-specific state for one upstream connection."
  @callback init(keyword()) :: {:ok, state()}

  @doc "Consumes one chunk and emits ordered complete records or immediate upstream replies."
  @callback handle_inbound(binary(), state()) ::
              {:ok, [action()], state()} | {:error, error_reason(), state()}
end
