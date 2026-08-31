import React from "react"

interface ChannelDirectoryPaginationProps {
  ariaLabel: string
  onPageChange: (page: number) => void
  page: number
  pageSize: number
  totalChannels: number
  totalPages: number
}

export default function ChannelDirectoryPagination({ariaLabel, onPageChange, page, pageSize, totalChannels, totalPages}: ChannelDirectoryPaginationProps) {
  if (totalPages <= 1) return null

  const firstChannel = (page - 1) * pageSize + 1
  const lastChannel = Math.min(page * pageSize, totalChannels)

  return (
    <nav aria-label={ariaLabel} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
      <p className="text-xs tabular-nums text-slate-500">
        Showing <span className="font-semibold text-slate-300">{firstChannel}–{lastChannel}</span> of {totalChannels} channels
      </p>
      <div className="flex items-center gap-2">
        <button
          aria-label="Previous channel page"
          className="inline-flex h-9 items-center gap-1.5 rounded-md border border-slate-700 px-3 text-xs font-semibold text-slate-300 transition hover:border-cyan-300/60 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
          disabled={page <= 1}
          onClick={() => onPageChange(page - 1)}
          type="button"
        >
          <span className="hero-chevron-left size-3.5" aria-hidden="true" />
          Previous
        </button>
        <span className="min-w-20 text-center text-xs font-medium tabular-nums text-slate-400">Page {page} of {totalPages}</span>
        <button
          aria-label="Next channel page"
          className="inline-flex h-9 items-center gap-1.5 rounded-md border border-slate-700 px-3 text-xs font-semibold text-slate-300 transition hover:border-cyan-300/60 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
          disabled={page >= totalPages}
          onClick={() => onPageChange(page + 1)}
          type="button"
        >
          Next
          <span className="hero-chevron-right size-3.5" aria-hidden="true" />
        </button>
      </div>
    </nav>
  )
}
