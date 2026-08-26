import React, {useState} from "react"
import UserGroup from "./user_group.tsx"
import type {Channel, ChatUser} from "../types.ts"

export function groupUsers(users: ChatUser[]): Array<{label: string; users: ChatUser[]}> {
  return [
    {label: "Mods", users: users.filter((user) => ["owner", "admin", "op", "halfop"].includes(user.role || ""))},
    {label: "Voiced", users: users.filter((user) => user.role === "voice")},
    {label: "Online", users: users.filter((user) => (!user.role || user.role === "user") && user.status !== "away")},
    {label: "Away", users: users.filter((user) => user.status === "away")},
  ].filter((group) => group.users.length > 0)
}

export default function RightSidebar({activeChannel, users, mobile = false}: {activeChannel?: Channel; users: ChatUser[]; mobile?: boolean}) {
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({})

  return (
    <aside className={[
      "min-h-0 border-l border-slate-800/80 bg-[#0f131b]",
      mobile ? "block min-h-0 flex-1 border-l-0" : "hidden lg:block",
    ].join(" ")} aria-label="People here">
      <div className="border-b border-slate-800/80 px-4 py-4">
        <h2 className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">People here</h2>
        <p className="mt-1 text-sm text-slate-300">{activeChannel?.channel || "#elixir"}</p>
      </div>
      <div className="max-h-[calc(100vh-5.5rem)] space-y-4 overflow-y-auto p-3">
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
