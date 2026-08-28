defmodule TopicsClubWeb.EngineNodeConnectorTest do
  use ExUnit.Case, async: false

  alias TopicsClubWeb.EngineNodeConnector

  test "starts without blocking and caps retries while the engine is unavailable" do
    connector_name = :engine_node_connector_unavailable_test

    start_supervised!(
      {EngineNodeConnector,
       engine_node: :missing_engine@localhost,
       name: connector_name,
       retry_min: 60_000,
       retry_max: 60_000}
    )

    _ = :sys.get_state(connector_name)

    assert EngineNodeConnector.status(connector_name) == %{
             connected?: false,
             engine_node: :missing_engine@localhost,
             retry_attempt: 1,
             status: :disconnected
           }
  end

  test "tracks node-up and node-down transitions for the configured engine only" do
    connector_name = :engine_node_connector_transition_test
    engine_node = :engine_transition_test@localhost

    start_supervised!(
      {EngineNodeConnector,
       engine_node: engine_node, name: connector_name, retry_min: 60_000, retry_max: 60_000}
    )

    _ = :sys.get_state(connector_name)
    send(connector_name, {:nodeup, engine_node, [node_type: :visible]})
    _ = :sys.get_state(connector_name)
    assert EngineNodeConnector.status(connector_name).connected?

    send(connector_name, {:nodedown, engine_node, [node_type: :visible]})
    _ = :sys.get_state(connector_name)

    assert EngineNodeConnector.status(connector_name) == %{
             connected?: false,
             engine_node: engine_node,
             retry_attempt: 1,
             status: :disconnected
           }
  end
end
