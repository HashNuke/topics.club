%{
  version: 1,
  ownership: [
    %{
      component: :shared,
      description: "Pure IRC protocol policy and identifiers shared by web, core, and engine",
      paths: [
        "lib/ircpipe/chat/mention_detection.ex",
        "lib/ircpipe/irc/command_registry.ex",
        "lib/ircpipe/irc/commands.ex",
        "lib/ircpipe/irc/identifier.ex"
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
        "lib/ircpipe/irc/**/*.ex",
        "test/support/closed_irc_session.ex",
        "test/support/crashing_irc_session.ex",
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
        "lib/ircpipe/chat/retention.ex",
        "lib/ircpipe/chat/server_connection.ex",
        "lib/ircpipe/chat/server_connection_lock.ex",
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
      components: [:core, :engine, :web],
      reason:
        "The initial monolith inventory contains explicitly allowlisted transition edges in both directions",
      remove_in: "checkpoint 5: all core/web and engine/web reverse edges removed"
    }
  ],
  temporary_dependency_budget: 36,
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
      from: "lib/ircpipe/chat/connection_deletion_worker.ex",
      to: "lib/ircpipe/chat/connections.ex",
      label: "runtime",
      owner: :engine,
      reason: "Engine deletion recovery still calls the web connection facade",
      remove_in: "checkpoint 5: engine-to-web effect cleanup"
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
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/chat/connection_deletion_request.ex",
      label: "export",
      owner: :web,
      reason: "The web connection facade still constructs an engine-owned deletion request",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe/chat/connection_snapshot.ex",
      to: "lib/ircpipe/chat/membership_reconciler.ex",
      label: "runtime",
      owner: :web,
      reason: "Web bootstrap snapshots still trigger engine-owned reconciliation",
      remove_in: "checkpoint 5: query and reconciliation split"
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/chat/connection_deletion_batch_store.ex",
      label: "runtime",
      owner: :web,
      reason: "The web connection facade still persists engine-owned deletion batches",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/chat/connection_deletion_events_worker.ex",
      label: "runtime",
      owner: :web,
      reason: "The web connection facade still dispatches an engine-owned deletion worker",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/chat/connection_deletion_worker.ex",
      label: "runtime",
      owner: :web,
      reason: "The web connection facade still schedules engine-owned deletion work",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/irc/connection_lock.ex",
      label: "runtime",
      owner: :web,
      reason: "The web connection facade still owns engine process serialization",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe/chat/connections.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "The web connection facade still quiesces the local engine directly",
      remove_in: "checkpoint 5: connection orchestration split"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Channel operations have not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Channel status lookup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Channel connection lifecycle has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel/buffer_resolver.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Buffer resolution still reads local session state",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel/channel_directory.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Live channel listing has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel/command_handler.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Command execution has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel/message_handler.ex",
      to: "lib/ircpipe/chat/system_messages.ex",
      label: "runtime",
      owner: :web,
      reason: "Web send failures still persist engine-owned system messages directly",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/channels/user_channel/message_handler.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Message sending has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/bootstrap_buffers.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Bootstrap status lookup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/bootstrap_controller.ex",
      to: "lib/ircpipe/chat/presence.ex",
      label: "runtime",
      owner: :web,
      reason: "Web bootstrap still invokes engine-owned presence reconciliation",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/bootstrap_controller.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Bootstrap status lookup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/bootstrap_controller.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Bootstrap connection startup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/channel_controller.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Channel operations have not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/channel_controller.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Channel connection startup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/connection_controller.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Connection status lookup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/connection_controller.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Connection lifecycle has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/discovery_controller.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Discovery join operations have not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/discovery_controller.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Discovery connection status has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/discovery_controller.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Discovery connection startup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/topic_controller.ex",
      to: "lib/ircpipe/irc/session.ex",
      label: "runtime",
      owner: :web,
      reason: "Topic join operations have not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/topic_controller.ex",
      to: "lib/ircpipe/irc/session_locator.ex",
      label: "runtime",
      owner: :web,
      reason: "Topic connection status has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    },
    %{
      from: "lib/ircpipe_web/controllers/api/topic_controller.ex",
      to: "lib/ircpipe/irc/session_supervisor.ex",
      label: "runtime",
      owner: :web,
      reason: "Topic connection startup has not moved behind EngineClient",
      remove_in: "checkpoint 4: web EngineClient routing"
    }
  ]
}
