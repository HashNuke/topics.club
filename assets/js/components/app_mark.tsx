import React from "react"

export default function AppMark({small = false}: {small?: boolean}) {
  return (
    <span
      className={[
        "grid place-items-center rounded-md bg-cyan-300 font-black text-cyan-950",
        small ? "size-7 text-xs" : "size-9 text-sm",
      ].join(" ")}
    >
      #
    </span>
  )
}
