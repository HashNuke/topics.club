import React from "react"
import UserListItem from "./user_list_item.tsx"
import type {ChatUser} from "../types.ts"

interface UserGroupProps {
  expanded?: boolean
  label: string
  onExpand?: () => void
  users: ChatUser[]
}

export default function UserGroup({expanded = false, label, onExpand, users}: UserGroupProps) {
  const visibleUsers = expanded ? users : users.slice(0, 10)
  const hiddenCount = users.length - visibleUsers.length

  return (
    <section>
      <div className="mb-1 flex items-center justify-between px-2 text-[0.65rem] font-semibold uppercase tracking-[0.16em] text-slate-600">
        <span>{label}</span>
        <span>{users.length}</span>
      </div>
      <div className="space-y-1">
        {visibleUsers.map((user) => <UserListItem key={user.nick} user={user} />)}
        {hiddenCount > 0 && (
          <button
            className="w-full rounded-md px-2 py-1.5 text-left text-xs font-semibold text-cyan-200 transition hover:bg-slate-800/70 hover:text-white"
            onClick={onExpand}
            type="button"
          >
            +{hiddenCount} more
          </button>
        )}
      </div>
    </section>
  )
}
