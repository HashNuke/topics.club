export function userRoleLabel(user) {
  if (["owner", "admin", "op", "halfop"].includes(user.role)) return "mod"
  if (user.role === "voice") return "voice"
  return "user"
}

export default function UserListItem({user}) {
  const role = userRoleLabel(user)

  return (
    <div className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm text-slate-300 hover:bg-slate-800/70">
      <span className={["size-2 rounded-full", user.status === "away" ? "bg-amber-300" : "bg-emerald-300"].join(" ")} aria-hidden="true" />
      <span className="min-w-0 flex-1 truncate">{user.nick}</span>
      <span
        className={[
          "rounded px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide",
          role === "mod"
            ? "bg-cyan-300/15 text-cyan-200"
            : role === "voice"
              ? "bg-violet-300/15 text-violet-200"
              : "bg-slate-800 text-slate-500",
        ].join(" ")}
      >
        {role}
      </span>
    </div>
  )
}
