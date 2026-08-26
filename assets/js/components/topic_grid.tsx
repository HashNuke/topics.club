import React from "react"
import {normalizeTopic} from "../chat_store.ts"
import type {Topic, TopicInput} from "../types.ts"

interface TopicCardProps {
  onSelectTopic: (topic: Topic) => void
  topic: Topic
}

export function TopicCard({onSelectTopic, topic}: TopicCardProps) {
  return (
    <button className="group rounded-lg border border-slate-800 bg-[#121722] p-3 text-left transition hover:-translate-y-0.5 hover:border-cyan-300 hover:bg-[#161d2a]" onClick={() => onSelectTopic(topic)} type="button">
      <div className="break-words text-lg font-semibold tracking-tight text-white">{topic.channel}</div>
      <div className="mt-0.5 truncate text-xs text-slate-500">on {topic.server_host}</div>
      <p className="mt-3 min-h-10 text-sm leading-5 text-slate-400">{topic.description}</p>
      <div className="mt-3 flex items-center justify-between text-xs text-slate-500">
        <span>{topic.members || "many"} online</span>
        <span className="font-semibold text-cyan-200 transition group-hover:text-white">Join</span>
      </div>
    </button>
  )
}

export default function TopicGrid({topics, onSelectTopic}: {topics: TopicInput[]; onSelectTopic: (topic: Topic) => void}) {
  return <div className="grid gap-3 sm:grid-cols-2">{topics.map((topic) => {
    const normalized = normalizeTopic(topic)
    return <TopicCard key={normalized.id} topic={normalized} onSelectTopic={onSelectTopic} />
  })}</div>
}
