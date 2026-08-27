import React, {type ReactNode} from "react"

export function MobileDrawer({children, onClose, side}: {children: ReactNode; onClose: () => void; side: "left" | "right"}) {
  return (
    <div className="fixed inset-0 z-50 lg:hidden">
      <button className="absolute inset-0 bg-black/70" onClick={onClose} aria-label="Close sidebar" type="button" />
      <div className={["absolute top-0 flex h-full w-[min(20rem,88vw)] flex-col bg-[var(--app-sidebar)] shadow-2xl shadow-black/50", side === "right" ? "right-0" : "left-0"].join(" ")}>
        {children}
      </div>
    </div>
  )
}

export function MobileDrawerHeader({title, onClose}: {title: string; onClose: () => void}) {
  return (
    <div className="flex h-14 shrink-0 items-center justify-between border-b border-slate-800/80 px-4">
      <div className="text-sm font-semibold uppercase tracking-[0.16em] text-slate-400">{title}</div>
      <button className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white" onClick={onClose} aria-label="Close sidebar" type="button">
        <span className="hero-x-mark size-5" aria-hidden="true" />
      </button>
    </div>
  )
}

export default MobileDrawer
