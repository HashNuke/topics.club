import React from "react"
import type {Topic} from "../types.ts"

interface AuthPromptProps {
  developerOauth: boolean
  topic: Topic
  onClose: () => void
}

export default function AuthPrompt({developerOauth, topic, onClose}: AuthPromptProps) {
  const topicParam = encodeURIComponent(topic.id)
  return <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
    <section aria-label="Sign in to join" className="w-full max-w-md rounded-lg border border-slate-700 bg-[var(--app-panel)] p-5 shadow-2xl" role="dialog">
      <div className="flex items-start justify-between gap-4">
        <div><h2 className="text-lg font-semibold">Sign in to join</h2><p className="mt-1 text-sm text-slate-400">{topic.channel}<span className="block text-xs text-slate-500">on {topic.server_host}</span></p></div>
        <button className="rounded-md p-2 text-slate-500 transition hover:bg-slate-800 hover:text-white" onClick={onClose} aria-label="Close sign in dialog" type="button"><span className="hero-x-mark size-4" aria-hidden="true" /></button>
      </div>
      <div className="mt-5 space-y-3">
        <a className="block rounded-md bg-white px-4 py-2.5 text-center text-sm font-semibold text-cyan-950 hover:bg-cyan-100" href={`/auth/google?topic=${topicParam}`}>Continue with Google</a>
        {developerOauth && <a className="block rounded-md border border-slate-700 px-4 py-2.5 text-center text-sm font-semibold text-slate-200 hover:border-cyan-300" href={`/auth/developer?topic=${topicParam}`}>Developer OAuth</a>}
      </div>
    </section>
  </div>
}
