%{
  version: 1,
  ownership: [
    %{
      component: :shared,
      description:
        "EngineClient port and versioned contracts plus IRC protocol policy and identifiers shared across roles",
      paths: [
        "lib/ircpipe/engine_client.ex",
        "lib/ircpipe/engine_client/adapter.ex",
        "lib/ircpipe/engine_client/contract.ex",
        "lib/ircpipe/engine_client/discovery.ex",
        "lib/ircpipe/engine_client/reply.ex",
        "lib/ircpipe/chat/mention_detection.ex",
        "lib/ircpipe/irc/command_registry.ex",
        "lib/ircpipe/irc/commands.ex",
        "lib/ircpipe/irc/identifier.ex",
        "test/support/engine_client_test_adapter.ex"
      ]
    },
    %{
      component: :engine,
      description: "Long-lived IRC process ownership, session orchestration, and ingestion",
      paths: [
        "lib/ircpipe/chat.ex",
        "lib/ircpipe/chat/channel_join_request.ex",
        "lib/ircpipe/chat/channel_part_lifecycle.ex",
        "lib/ircpipe/chat/command_messages.ex",
        "lib/ircpipe/chat/connection_activity.ex",
        "lib/ircpipe/chat/connection_casemapping.ex",
        "lib/ircpipe/chat/connection_deletion.ex",
        "lib/ircpipe/chat/connection_deletion_batch_store.ex",
        "lib/ircpipe/chat/connection_deletion_event_batch.ex",
        "lib/ircpipe/chat/connection_deletion_events_worker.ex",
        "lib/ircpipe/chat/connection_deletion_reconciler_worker.ex",
        "lib/ircpipe/chat/connection_deletion_request.ex",
        "lib/ircpipe/chat/connection_deletion_worker.ex",
        "lib/ircpipe/chat/connection_lifecycle.ex",
        "lib/ircpipe/chat/direct_message_ingestion.ex",
        "lib/ircpipe/chat/direct_message_renamer.ex",
        "lib/ircpipe/chat/direct_message_sender.ex",
        "lib/ircpipe/chat/membership_reconciler.ex",
        "lib/ircpipe/chat/message_ingestion.ex",
        "lib/ircpipe/chat/presence.ex",
        "lib/ircpipe/chat/presence_diff.ex",
        "lib/ircpipe/chat/presence_membership_lookup.ex",
        "lib/ircpipe/chat/system_messages.ex",
        "lib/ircpipe/engine/**/*.ex",
        "lib/ircpipe/engine_supervisor.ex",
        "lib/ircpipe/irc/**/*.ex",
        "test/support/closed_irc_session.ex",
        "test/support/crashing_irc_session.ex",
        "test/support/blocked_engine_api.ex",
        "test/support/failing_irc_client.ex",
        "test/support/irc_test_server.ex",
        "test/support/restarting_irc_session.ex"
      ],
      exclude: [
        "lib/ircpipe/chat/mention_detection.ex",
        "lib/ircpipe/irc/command_registry.ex",
        "lib/ircpipe/irc/commands.ex",
        "lib/ircpipe/irc/identifier.ex"
      ]
    },
    %{
      component: :web,
      description: "Phoenix, browser-facing behavior, notifications, and directory discovery",
      paths: [
        "lib/ircpipe/accounts.ex",
        "lib/ircpipe/accounts/scope.ex",
        "lib/ircpipe/accounts/user_notifier.ex",
        "lib/ircpipe/accounts/user_token.ex",
        "lib/ircpipe/chat/connection_attributes.ex",
        "lib/ircpipe/chat/connection_endpoint.ex",
        "lib/ircpipe/chat/connection_snapshot.ex",
        "lib/ircpipe/chat/connections.ex",
        "lib/ircpipe/chat/direct_message_lifecycle.ex",
        "lib/ircpipe/chat/message_history.ex",
        "lib/ircpipe/chat/read_state.ex",
        "lib/ircpipe/chat/topic.ex",
        "lib/ircpipe/chat/topics.ex",
        "lib/ircpipe/discovery.ex",
        "lib/ircpipe/discovery/**/*.ex",
        "lib/ircpipe/mailer.ex",
        "lib/ircpipe/notifications/**/*.ex",
        "lib/ircpipe/realtime/**/*.ex",
        "lib/ircpipe/engine_client/rpc_adapter.ex",
        "lib/ircpipe_web.ex",
        "lib/ircpipe_web/**/*.ex",
        "test/support/channel_case.ex",
        "test/support/conn_case.ex",
        "test/support/fixtures/accounts_fixtures.ex",
        "test/support/push_test_transport.ex"
      ]
    },
    %{
      component: :core,
      description: "Shared data, schemas, persistence primitives, and release migrations",
      paths: [
        "lib/ircpipe.ex",
        "lib/ircpipe/accounts/user.ex",
        "lib/ircpipe/chat/buffer_events.ex",
        "lib/ircpipe/chat/channel_membership.ex",
        "lib/ircpipe/chat/channel_user.ex",
        "lib/ircpipe/chat/direct_message_block_identity.ex",
        "lib/ircpipe/chat/direct_message_store.ex",
        "lib/ircpipe/chat/direct_message_thread.ex",
        "lib/ircpipe/chat/membership_lookup.ex",
        "lib/ircpipe/chat/message.ex",
        "lib/ircpipe/chat/notification.ex",
        "lib/ircpipe/chat/peer_identity.ex",
        "lib/ircpipe/chat/presence_queries.ex",
        "lib/ircpipe/chat/retention.ex",
        "lib/ircpipe/chat/server_connection.ex",
        "lib/ircpipe/chat/server_connection_lock.ex",
        "lib/ircpipe/core_supervisor.ex",
        "lib/ircpipe/encrypted/**/*.ex",
        "lib/ircpipe/release.ex",
        "lib/ircpipe/repo.ex",
        "lib/ircpipe/vault.ex",
        "priv/repo/migrations/*.exs",
        "test/support/data_case.ex",
        "test/support/migration_test_repo.ex"
      ]
    },
    %{
      component: :assembly,
      description: "Temporary combined-application composition root",
      paths: ["lib/ircpipe/application.ex"]
    },
    %{
      component: :tooling,
      description: "Development and release tooling that is not runtime domain code",
      paths: ["lib/mix/**/*.ex"]
    }
  ],
  allowed_dependencies: %{
    shared: [:shared],
    core: [:core, :shared],
    engine: [:engine, :core, :shared],
    web: [:web, :core, :shared],
    assembly: [:assembly, :core, :engine, :shared, :web],
    tooling: [:assembly, :core, :engine, :shared, :tooling, :web]
  },
  temporary_component_cycles: [
    %{
      components: [:core, :web],
      reason:
        "The remaining core BufferEvents bridge still constructs web-owned browser event payloads",
      remove_in: "checkpoint 5: stable internal event boundary"
    }
  ],
  temporary_dependency_budget: 6,
  temporary_dependencies: [
    %{
      from: "lib/ircpipe/chat/buffer_events.ex",
      to: "lib/ircpipe/realtime/event.ex",
      label: "runtime",
      owner: :core,
      reason: "Core PubSub publishing still constructs browser-shaped payloads",
      remove_in: "checkpoint 5: stable internal event boundary"
    },
    %{
      from: "lib/ircpipe/chat/connection_lifecycle.ex",
      to: "lib/ircpipe/realtime/event.ex",
      label: "runtime",
      owner: :engine,
      reason: "Engine connection lifecycle still constructs browser-shaped payloads",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
    },
    %{
      from: "lib/ircpipe/chat/direct_message_ingestion.ex",
      to: "lib/ircpipe/notifications/delivery.ex",
      label: "runtime",
      owner: :engine,
      reason: "Canonical ingestion still invokes web-owned push enqueueing directly",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
    },
    %{
      from: "lib/ircpipe/chat/membership_reconciler.ex",
      to: "lib/ircpipe/realtime/event.ex",
      label: "runtime",
      owner: :engine,
      reason: "Engine membership reconciliation still constructs browser-shaped payloads",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
    },
    %{
      from: "lib/ircpipe/chat/message_ingestion.ex",
      to: "lib/ircpipe/notifications/delivery.ex",
      label: "runtime",
      owner: :engine,
      reason: "Canonical ingestion still invokes web-owned push enqueueing directly",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
    },
    %{
      from: "lib/ircpipe/chat/presence.ex",
      to: "lib/ircpipe/realtime/event.ex",
      label: "runtime",
      owner: :engine,
      reason: "Engine presence persistence still constructs browser-shaped payloads",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
    }
  ]
}
