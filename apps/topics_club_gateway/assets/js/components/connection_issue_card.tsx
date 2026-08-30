import React, {useState} from "react"
import {connectionIssueGuidance, type ConnectionIssue} from "../connection_issue.ts"
import type {ServerConnection} from "../types.ts"

export interface ConnectionIssueCardProps {
  issue: ConnectionIssue
  onEditServer: (server: ServerConnection, focus: ConnectionIssue["edit_focus"]) => void
  onReconnectServer: (server: ServerConnection) => void
  onUseRandomNickname: (server: ServerConnection) => boolean | Promise<boolean>
  server: ServerConnection
}

export default function ConnectionIssueCard({issue, onEditServer, onReconnectServer, onUseRandomNickname, server}: ConnectionIssueCardProps) {
  const [randomNicknameError, setRandomNicknameError] = useState(false)
  const [randomNicknameSaving, setRandomNicknameSaving] = useState(false)
  const nicknameIssue = issue.edit_focus === "nickname"
  const editLabel = issue.edit_focus === "credentials"
      ? "Edit credentials"
      : "Edit connection"

  async function useRandomNickname() {
    setRandomNicknameError(false)
    setRandomNicknameSaving(true)
    const updated = await onUseRandomNickname(server)
    setRandomNicknameSaving(false)
    setRandomNicknameError(!updated)
  }

  return (
    <section
      id="connection-issue-card"
      className="mb-4 overflow-hidden rounded-xl border border-amber-300/25 bg-gradient-to-br from-amber-300/12 via-amber-200/6 to-transparent shadow-lg shadow-black/10"
      aria-labelledby="connection-issue-title"
    >
      <div className="p-4 sm:p-5">
        <div className="flex items-start gap-3">
          <span className="grid size-9 shrink-0 place-items-center rounded-full bg-amber-300/15 text-amber-200" aria-hidden="true">
            <span className="hero-exclamation-triangle size-5" />
          </span>
          <div className="min-w-0 flex-1">
            <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-amber-200/65">Connection needs attention</p>
            <h3 id="connection-issue-title" className="mt-1 text-base font-semibold text-amber-50 sm:text-lg">{issue.title}</h3>
            <p className="mt-1.5 text-sm leading-6 text-amber-50/75">{connectionIssueGuidance(issue)}</p>
          </div>
        </div>

        {issue.technical_details && (
          <details className="mt-4 rounded-lg border border-white/8 bg-black/15 px-3 py-2">
            <summary className="cursor-pointer select-none text-xs font-semibold text-amber-100/70">Technical details</summary>
            <p className="mt-2 break-words font-mono text-xs leading-5 text-slate-400">{issue.technical_details}</p>
          </details>
        )}

        {randomNicknameError && (
          <p className="mt-4 text-sm text-rose-200" role="alert">
            The nickname could not be changed. Edit the connection and choose one yourself.
          </p>
        )}

        <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:justify-end">
          {!nicknameIssue && (
            <button
              id="connection-issue-reconnect-button"
              className="min-h-11 rounded-lg border border-amber-100/25 px-4 py-2 text-sm font-semibold text-amber-50 transition hover:border-amber-100/60 hover:bg-amber-50/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-200/70 sm:min-h-0"
              onClick={() => onReconnectServer(server)}
              type="button"
            >
              Reconnect
            </button>
          )}
          <button
            id="connection-issue-edit-button"
            className={[
              "min-h-11 rounded-lg px-4 py-2 text-sm font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-100 sm:min-h-0",
              nicknameIssue
                ? "border border-amber-100/25 text-amber-50 hover:border-amber-100/60 hover:bg-amber-50/10"
                : "bg-amber-200 text-amber-950 hover:bg-white",
            ].join(" ")}
            onClick={() => onEditServer(server, issue.edit_focus)}
            type="button"
          >
            {editLabel}
          </button>
          {nicknameIssue && (
            <button
              id="connection-issue-random-nickname-button"
              className="min-h-11 rounded-lg bg-amber-200 px-4 py-2 text-sm font-semibold text-amber-950 transition hover:bg-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-100 disabled:cursor-wait disabled:bg-amber-100/45 disabled:text-amber-950/65 sm:min-h-0"
              disabled={randomNicknameSaving}
              onClick={useRandomNickname}
              type="button"
            >
              {randomNicknameSaving ? "Choosing…" : "Choose a random nickname"}
            </button>
          )}
        </div>
      </div>
    </section>
  )
}
