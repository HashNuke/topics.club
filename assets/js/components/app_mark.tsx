import React from "react"

export default function AppMark({small = false}: {small?: boolean}) {
  return (
    <span
      className={[
        "inline-flex items-baseline whitespace-nowrap font-semibold tracking-[-0.045em] text-slate-100",
        "transition-colors duration-200 group-hover:text-white",
        small ? "text-[0.95rem]" : "text-xl",
      ].join(" ")}
    >
      <span>topics</span><span className="text-cyan-300">.club</span>
    </span>
  )
}
