defmodule TopicsClubWeb.RpcEngineAPIStub do
  @moduledoc false

  alias TopicsClub.EngineClient.Contract
  alias TopicsClub.EngineClient.Reply

  def dispatch(request) do
    case Application.get_env(:topics_club_gateway, :rpc_engine_api_stub_mode) do
      :block ->
        receive do
          :release -> Reply.error(request, :internal_error)
        end

      _reply ->
        Reply.ok(request, %{
          active_sessions: 0,
          engine_node: Atom.to_string(node()),
          marker: %{
            owner_node: Atom.to_string(node()),
            started_at: "2026-08-28T10:11:12Z",
            status: :owner
          },
          operations: Contract.operations(),
          protocol_version: Contract.version()
        })
    end
  end
end
