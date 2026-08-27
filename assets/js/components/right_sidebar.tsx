import React, {useState} from "react"
import UserGroup from "./user_group.tsx"
import type {Channel, ChatUser, DirectMessageChannel} from "../types.ts"

export function groupUsers(users: ChatUser[]): Array<{label: string; users: ChatUser[]}> {
  return [
    {label: "Mods", users: users.filter((user) => ["owner", "admin", "op", "halfop"].includes(user.role || ""))},
    {label: "Voiced", users: users.filter((user) => user.role === "voice")},
    {label: "Online", users: users.filter((user) => (!user.role || user.role === "user") && user.status !== "away")},
    {label: "Away", users: users.filter((user) => user.status === "away")},
  ].filter((group) => group.users.length > 0)
}

export default function RightSidebar({activeChannel, users, mobile = false, onCloseMobile, onSetDirectMessageBlocked}: {activeChannel?: Channel; users: ChatUser[]; mobile?: boolean; onCloseMobile?: () => void; onSetDirectMessageBlocked: (channel: Channel, blocked: boolean) => void}) {
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({})

  if (activeChannel?.buffer_type === "direct_message") {
    return <DirectMessagePeerSidebar
      activeChannel={activeChannel}
      mobile={mobile}
      onCloseMobile={onCloseMobile}
      onSetBlocked={onSetDirectMessageBlocked}
    />
  }

  return (
    <aside className={[
      "min-h-0 border-l border-slate-800/80 bg-[var(--app-sidebar)]",
      mobile ? "flex min-h-0 flex-1 flex-col border-l-0" : "hidden lg:block",
    ].join(" ")} aria-label="People here">
      <div className="flex min-h-14 shrink-0 items-center justify-between gap-3 border-b border-slate-800/80 px-4 py-3">
        <div className="min-w-0">
          <h2 className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">People here</h2>
          <p className="mt-1 truncate text-sm text-slate-300">{activeChannel?.channel || "#elixir"}</p>
        </div>
        {mobile && onCloseMobile && (
          <button className="grid size-8 shrink-0 place-items-center rounded-lg border border-white/8 text-white/70 transition hover:border-cyan-300/40 hover:bg-white/6 hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" onClick={onCloseMobile} aria-label="Close sidebar" type="button">
            <span className="hero-x-mark size-4" aria-hidden="true" />
          </button>
        )}
      </div>
      <div className={[
        "space-y-4 overflow-y-auto overscroll-contain p-3",
        mobile ? "min-h-0 flex-1" : "max-h-[calc(100vh-5.5rem)]",
      ].join(" ")}>
        {groupUsers(users).map((group) => (
          <UserGroup
            key={group.label}
            expanded={Boolean(expandedGroups[group.label])}
            label={group.label}
            onExpand={() => setExpandedGroups((current) => ({...current, [group.label]: true}))}
            users={group.users}
          />
        ))}
      </div>
    </aside>
  )
}

function DirectMessagePeerSidebar({activeChannel, mobile, onCloseMobile, onSetBlocked}: {activeChannel: DirectMessageChannel; mobile: boolean; onCloseMobile?: () => void; onSetBlocked: (channel: Channel, blocked: boolean) => void}) {
  const identity = activeChannel.account || activeChannel.hostmask || "Identity unavailable on this network"

  return (
    <aside className={[
      "min-h-0 border-l border-slate-800/80 bg-[var(--app-sidebar)]",
      mobile ? "flex min-h-0 flex-1 flex-col border-l-0" : "hidden lg:block",
    ].join(" ")} aria-label={`About ${activeChannel.channel}`}>
      <div className="flex min-h-14 shrink-0 items-start justify-between gap-3 border-b border-slate-800/80 px-4 py-3">
        <div className="min-w-0">
          <h2 className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Private message</h2>
          <div className="mt-3 flex items-center gap-3">
            <div className="grid size-10 place-items-center rounded-full border border-cyan-300/25 bg-cyan-300/10 text-cyan-200">
              <span className="hero-user size-5" aria-hidden="true" />
            </div>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-slate-100">{activeChannel.channel}</p>
              <p className="truncate text-xs text-slate-500">{activeChannel.topic}</p>
            </div>
          </div>
        </div>
        {mobile && onCloseMobile && (
          <button className="grid size-8 shrink-0 place-items-center rounded-lg border border-white/8 text-white/70 transition hover:border-cyan-300/40 hover:bg-white/6 hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" onClick={onCloseMobile} aria-label="Close sidebar" type="button">
            <span className="hero-x-mark size-4" aria-hidden="true" />
          </button>
        )}
      </div>
      <div className={["space-y-4 p-4", mobile && "min-h-0 flex-1 overflow-y-auto overscroll-contain"].filter(Boolean).join(" ")}>
        <div className="rounded-lg border border-slate-800 bg-slate-950/50 p-3">
          <p className="text-[0.65rem] font-semibold uppercase tracking-[0.16em] text-slate-600">Known identity</p>
          <p className="mt-1 break-all text-xs text-slate-300">{identity}</p>
        </div>
        <button
          id={`${mobile ? "mobile" : "desktop"}-direct-message-block-button`}
          className={[
            "w-full rounded-md border px-3 py-2 text-sm font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70",
            activeChannel.blocked
              ? "border-emerald-300/40 bg-emerald-300/10 text-emerald-200 hover:bg-emerald-300/20"
              : "border-rose-300/30 bg-rose-300/10 text-rose-200 hover:bg-rose-300/20",
          ].join(" ")}
          onClick={() => onSetBlocked(activeChannel, !activeChannel.blocked)}
          type="button"
        >
          {activeChannel.blocked ? "Unblock user" : "Block user"}
        </button>
        <p className="text-xs leading-5 text-slate-500">
          Blocked private messages are discarded and will not create unread activity or notifications.
        </p>
      </div>
    </aside>
  )
}
