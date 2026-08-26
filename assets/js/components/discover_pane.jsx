import React from "react"
import TopicGrid from "./topic_grid.jsx"

export default function DiscoverPane({topics, onSelectTopic}) {
  return <section className="min-h-0 flex-1 overflow-y-auto bg-[#090b10] p-4 sm:p-6">
    <div className="mx-auto max-w-5xl">
      <div className="mb-5"><h2 className="text-2xl font-semibold tracking-tight">Discover topics</h2><p className="mt-1 text-sm text-slate-500">Join a suggested conversation or add your own server from the sidebar.</p></div>
      <TopicGrid topics={topics} onSelectTopic={onSelectTopic} />
    </div>
  </section>
}
