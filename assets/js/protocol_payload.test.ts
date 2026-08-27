import {describe, expect, test} from "vitest"
import {
  validBufferId,
  validBufferLeftPayload,
  validBufferReadPayload,
  validBufferRecord,
  validDirectMessageThreadPayload,
  validEntityId,
  validJoinedTopicPayload,
  validNotificationPreferenceResponse,
  validNotificationPreferenceEventPayload,
  validNotificationPreferencePayload,
  validServerDeletedPayload,
  validServerStatusPayload,
} from "./protocol_payload.ts"

const occurredAt = "2026-08-27T00:00:00Z"

describe("protocol payload primitives", () => {
  test("bounds entity and buffer IDs to PostgreSQL signed bigint", () => {
    expect(validEntityId("9223372036854775807")).toBe(true)
    expect(validEntityId("9223372036854775808")).toBe(false)
    expect(validEntityId("9999999999999999999")).toBe(false)
    expect(validBufferId("channel:9223372036854775807")).toBe(true)
    expect(validBufferId("channel:9223372036854775808")).toBe(false)
  })

  test("accepts only canonical server statuses", () => {
    const payload = {
      type: "server:status",
      version: 1,
      event_id: "server_status:42:1",
      occurred_at: occurredAt,
      server_connection_id: 42,
      nickname: "mira",
      status: "connected",
    }

    for (const status of ["disconnected", "connecting", "connected", "errored"]) {
      expect(validServerStatusPayload({...payload, status})).toBe(true)
    }

    expect(validServerStatusPayload({...payload, status: "paused"})).toBe(false)
    expect(validServerStatusPayload({...payload, status: ""})).toBe(false)
  })

  test("validates exact server deletion acknowledgements", () => {
    const payload = {
      type: "server:deleted",
      version: 1,
      event_id: "server_deleted:42:1",
      occurred_at: occurredAt,
      server_connection_id: 42,
    }

    expect(validServerDeletedPayload(payload)).toBe(true)
    expect(validServerDeletedPayload({server_connection_id: 42})).toBe(false)
    expect(validServerDeletedPayload({...payload, event_id: "server_deleted:41:1"})).toBe(false)
  })

  test("separates bare HTTP preferences from versioned realtime events", () => {
    const preference = {
      scope: "channel",
      id: 7,
      mention_notifications_enabled: false,
      revision: 2,
    }
    const event = {
      ...preference,
      type: "notification:preference",
      version: 1,
      event_id: "notification_preference:channel:7:2",
      occurred_at: occurredAt,
    }

    expect(validNotificationPreferencePayload(preference)).toBe(true)
    expect(validNotificationPreferenceEventPayload(event)).toBe(true)
    expect(validNotificationPreferenceEventPayload(preference)).toBe(false)
    expect(validNotificationPreferenceEventPayload({...event, event_id: "notification_preference:channel:7:1"})).toBe(false)
  })

  test("rejects records and events with contradictory buffer owners", () => {
    const channel = {
      buffer_id: "channel:7",
      buffer_type: "channel",
      server_connection_id: 42,
      channel_membership_id: 7,
      title: "#elixir",
      mention_notifications_enabled: true,
      notification_preference_revision: 0,
    }
    const read = {
      type: "buffer:read",
      version: 1,
      event_id: "buffer_read:channel:7:1",
      occurred_at: occurredAt,
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
      unread_count: 0,
      mention_count: 0,
    }
    const left = {
      ...read,
      type: "buffer:left",
      event_id: "buffer_left:channel:7:1",
    }

    expect(validBufferRecord(channel)).toBe(true)
    expect(validBufferRecord({...channel, direct_message_thread_id: 8})).toBe(false)
    expect(validBufferReadPayload({...read, direct_message_thread_id: 8})).toBe(false)
    expect(validBufferLeftPayload({...left, direct_message_thread_id: 8})).toBe(false)
  })

  test("rejects malformed nested channel and direct-message fields", () => {
    const connection = {
      id: 42,
      host: "irc.example.test",
      status: "connected",
      mention_notifications_enabled: true,
      notification_preference_revision: 0,
    }
    const channel = {
      buffer_id: "channel:7",
      buffer_type: "channel",
      server_connection_id: 42,
      channel_membership_id: 7,
      title: "#elixir",
      subtitle: "on irc.example.test",
      status: "connected",
      mention_notifications_enabled: true,
      notification_preference_revision: 0,
    }
    const topic = {
      id: 9,
      channel: "#elixir",
      name: "#elixir",
      server_host: "irc.example.test",
      server_port: 6697,
      use_tls: true,
      description: "Elixir discussion",
    }
    const directMessage = {
      buffer_id: "direct:8",
      buffer_type: "direct_message",
      server_connection_id: 42,
      direct_message_thread_id: 8,
      direct_message_revision: 1,
      title: "mira",
      subtitle: "on irc.example.test",
      status: "connected",
      peer_nick: "mira",
      account: null,
      hostmask: null,
      closed_at: null,
      unread_count: 0,
      mention_count: 0,
      blocked: false,
    }
    const directMessageEvent = {
      type: "direct_message:thread",
      version: 1,
      event_id: "direct_message_thread:8:1",
      occurred_at: occurredAt,
      connection,
      buffer: directMessage,
      revision: 1,
    }

    expect(validJoinedTopicPayload({connection, buffer: channel, topic})).toBe(true)
    expect(validJoinedTopicPayload({connection, buffer: {...channel, subtitle: {}}})).toBe(false)
    expect(validJoinedTopicPayload({connection, buffer: channel, topic: {...topic, description: {}}})).toBe(false)
    expect(validDirectMessageThreadPayload(directMessageEvent)).toBe(true)
    expect(validDirectMessageThreadPayload({
      ...directMessageEvent,
      buffer: {...directMessage, status: "paused"},
    })).toBe(false)
  })

  test("accepts only the exact advancing HTTP notification preference response", () => {
    const expected = {
      scope: "channel" as const,
      id: 7,
      mention_notifications_enabled: false,
      baseRevision: 1,
    }
    const response = {
      scope: "channel",
      id: 7,
      mention_notifications_enabled: false,
      revision: 2,
    }

    expect(validNotificationPreferenceResponse(response, expected)).toBe(true)
    expect(validNotificationPreferenceResponse({...response, id: 8}, expected)).toBe(false)
    expect(validNotificationPreferenceResponse({...response, scope: "server"}, expected)).toBe(false)
    expect(validNotificationPreferenceResponse({...response, mention_notifications_enabled: true}, expected)).toBe(false)
    expect(validNotificationPreferenceResponse({...response, revision: 1}, expected)).toBe(false)
    expect(validNotificationPreferenceResponse({preference: response}, expected)).toBe(false)
  })
})
