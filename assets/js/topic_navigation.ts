import {normalizeTopic} from "./chat_store.ts"
import type {EntityId, Topic, TopicInput} from "./types.ts"

export function numericId(value: unknown): number | null {
  const parsed = Number(value)
  return Number.isInteger(parsed) ? parsed : null
}

export function backendTopicFor(topic: Topic, topics: TopicInput[]): TopicInput | undefined {
  return topics.find((candidate) => {
    const normalized = normalizeTopic(candidate)

    return (
      numericId(normalized.id) &&
      normalized.channel === topic.channel &&
      normalized.server_host === topic.server_host &&
      Number(normalized.server_port || 6669) === Number(topic.server_port || 6669)
    )
  })
}

export function topicForRequestedId(requestedId: EntityId | null, topics: Topic[]): Topic | null {
  return topics.find((topic) => String(topic.id) === String(requestedId)) || null
}

export function requestedTopicId(): string | null {
  if (typeof window === "undefined") return null
  return new URLSearchParams(window.location.search).get("topic")
}
