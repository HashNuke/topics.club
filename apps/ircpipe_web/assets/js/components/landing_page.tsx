import React from "react"
import AppMark from "./app_mark.tsx"
import DiscoveryChannelCard from "./discovery_channel_card.tsx"
import type {CurrentUser, ServerChannel} from "../types.ts"

interface LandingPageProps {
  currentUser?: CurrentUser | null
  featuredChannels: ServerChannel[]
  loading?: boolean
}

export default function LandingPage({currentUser, featuredChannels, loading = false}: LandingPageProps) {
  return (
    <main className="relative min-h-screen overflow-hidden bg-[var(--app-canvas)] text-slate-100">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-[34rem] bg-[radial-gradient(circle_at_50%_-12%,rgba(181,167,255,0.16),transparent_58%)]" />
      <header className="relative mx-auto flex h-20 max-w-6xl items-center justify-between px-5 sm:px-7">
        <a href="/" className="group rounded-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" aria-label="topics.club home">
          <AppMark />
        </a>
        {currentUser ? (
          <a className="rounded-xl bg-white px-4 py-2.5 text-sm font-semibold text-cyan-950 shadow-lg shadow-black/15 transition duration-200 hover:-translate-y-px hover:bg-cyan-100" href="/chat">Open chat</a>
        ) : (
          <a className="rounded-xl bg-white px-4 py-2.5 text-sm font-semibold text-cyan-950 shadow-lg shadow-black/15 transition duration-200 hover:-translate-y-px hover:bg-cyan-100 hover:shadow-xl" href="/auth/google">Continue with Google</a>
        )}
      </header>

      <section aria-labelledby="featured-channels-heading" className="relative mx-auto max-w-6xl px-5 pb-16 pt-16 sm:px-7 sm:pb-24 sm:pt-24">
        <div className="max-w-2xl">
          <div className="mb-4 flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.18em] text-cyan-200">
            <span className="hero-globe-alt size-3.5" aria-hidden="true" />
            Across IRC
          </div>
          <h1 id="featured-channels-heading" className="text-3xl font-semibold tracking-[-0.045em] text-white min-[360px]:text-4xl sm:text-5xl">Featured channels</h1>
          <p className="mt-4 max-w-xl text-sm leading-6 text-slate-400 sm:text-base">A handful of IRC communities, ready when you are.</p>
        </div>

        {loading ? (
          <div className="mt-10 grid gap-3 sm:grid-cols-2 lg:grid-cols-3" aria-label="Loading featured channels" role="status">
            {Array.from({length: 6}, (_, index) => <div key={index} className="h-40 animate-pulse rounded-2xl border border-white/6 bg-white/3" />)}
          </div>
        ) : featuredChannels.length > 0 ? (
          <div className="mt-10 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {featuredChannels.map((serverChannel) => <DiscoveryChannelCard key={serverChannel.id} serverChannel={serverChannel} />)}
          </div>
        ) : (
          <div className="mt-10 rounded-2xl border border-dashed border-white/10 px-6 py-14 text-center">
            <p className="text-sm font-semibold text-slate-300">Featured channels are being refreshed</p>
            <p className="mt-1 text-xs text-slate-600">Check back in a little while.</p>
          </div>
        )}
      </section>
    </main>
  )
}
