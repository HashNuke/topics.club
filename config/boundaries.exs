%{
  version: 1,
  ownership: [
    %{
      component: :shared,
      description:
        "EngineClient port and versioned contracts plus IRC protocol policy and identifiers shared across roles",
      paths: [
        "apps/ircpipe_core/lib/ircpipe/engine_client.ex",
        "apps/ircpipe_core/lib/ircpipe/engine_client/adapter.ex",
        "apps/ircpipe_core/lib/ircpipe/engine_client/contract.ex",
        "apps/ircpipe_core/lib/ircpipe/engine_client/discovery.ex",
        "apps/ircpipe_core/lib/ircpipe/engine_client/reply.ex",
        "apps/ircpipe_core/lib/ircpipe/internal_event.ex",
        "apps/ircpipe_core/lib/ircpipe/internal_event/adapter.ex",
        "apps/ircpipe_core/lib/ircpipe/internal_event/data.ex",
        "apps/ircpipe_core/lib/ircpipe/internal_events.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/mention_detection.ex",
        "apps/ircpipe_core/lib/ircpipe/irc/command_registry.ex",
        "apps/ircpipe_core/lib/ircpipe/irc/commands.ex",
        "apps/ircpipe_core/lib/ircpipe/irc/identifier.ex",
        "apps/ircpipe_core/test/support/engine_client_test_adapter.ex"
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
        "lib/ircpipe/chat/notification_events_worker.ex",
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
        "apps/ircpipe_core/lib/ircpipe.ex",
        "apps/ircpipe_core/lib/ircpipe/accounts/user.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/buffer_events.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/channel_membership.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/channel_user.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/direct_message_block_identity.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/direct_message_store.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/direct_message_thread.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/membership_lookup.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/message.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/notification.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/peer_identity.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/presence_queries.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/retention.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/server_connection.ex",
        "apps/ircpipe_core/lib/ircpipe/chat/server_connection_lock.ex",
        "apps/ircpipe_core/lib/ircpipe/core/application.ex",
        "apps/ircpipe_core/lib/ircpipe/core_supervisor.ex",
        "apps/ircpipe_core/lib/ircpipe/encrypted/**/*.ex",
        "apps/ircpipe_core/lib/ircpipe/release.ex",
        "apps/ircpipe_core/lib/ircpipe/repo.ex",
        "apps/ircpipe_core/lib/ircpipe/vault.ex",
        "apps/ircpipe_core/priv/repo/migrations/*.exs",
        "apps/ircpipe_core/test/support/data_case.ex",
        "apps/ircpipe_core/test/support/migration_test_repo.ex"
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
  temporary_component_cycles: [],
  temporary_dependency_budget: 0,
  temporary_dependencies: []
}
