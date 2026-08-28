defmodule TopicsClub.EngineClient.RpcAdapterTest do
  use ExUnit.Case, async: false

  alias TopicsClub.EngineClient
  alias TopicsClub.EngineClient.Discovery
  alias TopicsClub.EngineClient.RpcAdapter

  test "calls the configured marker owner and normalizes split-node failures" do
    started_distribution? = start_distribution()

    on_exit(fn ->
      if started_distribution?, do: :net_kernel.stop()
    end)

    peer_name = :rpc_adapter_engine_peer

    peer_pid =
      start_supervised!(%{
        id: peer_name,
        start:
          {:peer, :start_link,
           [
             %{
               name: peer_name,
               connection: :standard_io,
               shutdown: 5_000,
               args: peer_code_path_args()
             }
           ]},
        restart: :temporary,
        shutdown: 10_000
      })

    peer_node = :peer.call(peer_pid, :erlang, :node, [])
    assert Node.connect(peer_node)

    marker_pid = :peer.call(peer_pid, :erlang, :whereis, [:init])
    assert :yes = :global.register_name(Discovery.marker_name(), marker_pid)
    assert {:ok, ^marker_pid} = Discovery.whereis()
    assert {:ok, ^peer_node} = Discovery.engine_node(peer_node)

    previous = configure_rpc_adapter(peer_node)

    on_exit(fn ->
      :global.unregister_name(Discovery.marker_name())
      restore_env(previous)
    end)

    assert {:ok, info} =
             EngineClient.protocol_info(request_id: "remote-protocol-info", timeout: 1_000)

    assert info.engine_node == Atom.to_string(peer_node)
    assert info.protocol_version == 1

    assert :ok =
             :peer.call(peer_pid, Application, :put_env, [
               :topics_club_gateway,
               :rpc_engine_api_stub_mode,
               :block
             ])

    assert {:error, %{code: :timeout}} =
             EngineClient.protocol_info(request_id: "remote-timeout", timeout: 20)

    assert :ok =
             :peer.call(peer_pid, Application, :delete_env, [
               :topics_club_gateway,
               :rpc_engine_api_stub_mode
             ])

    Application.put_env(:topics_club_gateway, :engine_node, :unexpected_engine@localhost)

    assert {:error, %{code: :engine_unavailable}} =
             EngineClient.protocol_info(request_id: "remote-marker-mismatch", timeout: 100)

    Application.put_env(:topics_club_gateway, :engine_node, peer_node)
    assert :ok = stop_supervised(peer_name)
    assert {:error, :engine_unavailable} = Discovery.whereis()

    assert {:error, %{code: :engine_unavailable}} =
             EngineClient.protocol_info(request_id: "remote-node-down", timeout: 100)
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:rpc_adapter_gateway_test, :shortnames])
      true
    end
  end

  defp peer_code_path_args do
    :code.get_path()
    |> Enum.reject(&(List.to_string(&1) == "."))
    |> Enum.flat_map(&[~c"-pa", &1])
  end

  defp configure_rpc_adapter(peer_node) do
    previous = %{
      adapter: Application.get_env(:topics_club_core, :engine_client_adapter),
      engine_node: Application.get_env(:topics_club_gateway, :engine_node),
      rpc_api: Application.get_env(:topics_club_gateway, :engine_rpc_api_module),
      stub_mode: Application.get_env(:topics_club_gateway, :rpc_engine_api_stub_mode)
    }

    Application.put_env(:topics_club_core, :engine_client_adapter, RpcAdapter)
    Application.put_env(:topics_club_gateway, :engine_node, peer_node)

    Application.put_env(
      :topics_club_gateway,
      :engine_rpc_api_module,
      TopicsClubWeb.RpcEngineAPIStub
    )

    previous
  end

  defp restore_env(previous) do
    restore(:topics_club_core, :engine_client_adapter, previous.adapter)
    restore(:topics_club_gateway, :engine_node, previous.engine_node)
    restore(:topics_club_gateway, :engine_rpc_api_module, previous.rpc_api)
    restore(:topics_club_gateway, :rpc_engine_api_stub_mode, previous.stub_mode)
  end

  defp restore(application, key, nil), do: Application.delete_env(application, key)
  defp restore(application, key, value), do: Application.put_env(application, key, value)
end
