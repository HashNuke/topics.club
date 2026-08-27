import React from "react"
import AppMark from "./app_mark.tsx"
import AuthPrompt from "./auth_prompt.tsx"
import TopicGrid from "./topic_grid.tsx"
import type {CurrentUser, Topic} from "../types.ts"

interface LandingPageProps {
  currentUser?: CurrentUser | null
  topics: Topic[]
  developerOauth: boolean
  selectedTopic?: Topic | null
  onSelectTopic: (topic: Topic) => void
  onCloseAuth: () => void
}

export default function LandingPage({currentUser, topics, developerOauth, selectedTopic, onSelectTopic, onCloseAuth}: LandingPageProps) {
  return <main className="min-h-screen bg-[#090b10] text-slate-100">
    <section className="mx-auto grid min-h-screen max-w-7xl content-center gap-8 px-5 py-8 lg:grid-cols-[0.9fr_1.1fr]">
      <div className="self-center">
        <div className="mb-8 flex items-center gap-3"><AppMark /><span className="text-xl font-semibold tracking-tight">topics.club</span></div>
        <h1 className="mt-4 max-w-xl text-5xl font-semibold leading-[1.02] tracking-tight text-white sm:text-6xl">Community chat</h1>
        <p className="mt-5 text-sm font-semibold uppercase tracking-[0.2em] text-cyan-300">IRC, made easy</p>
        <div className="mt-8 flex flex-wrap gap-3">
          <a className="rounded-md bg-white px-4 py-2.5 text-sm font-semibold text-cyan-950 transition hover:bg-cyan-100" href="/chat">Open chat</a>
          {!currentUser && developerOauth && <a className="rounded-md border border-slate-700 px-4 py-2.5 text-sm font-semibold text-slate-200 transition hover:border-cyan-300 hover:text-white" href="/auth/developer">Developer OAuth</a>}
        </div>
      </div>
      <section aria-label="Suggested topics" className="self-center"><h2 className="mb-3 text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Start here</h2><TopicGrid topics={topics} onSelectTopic={onSelectTopic} /></section>
    </section>
    {selectedTopic && <AuthPrompt developerOauth={developerOauth} topic={selectedTopic} onClose={onCloseAuth} />}
  </main>
}
