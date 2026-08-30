import {useEffect, useState} from "react"

export function documentVisible(): boolean {
  return document.visibilityState === "visible"
}

export default function useDocumentVisibility(): boolean {
  const [visible, setVisible] = useState(documentVisible)

  useEffect(() => {
    const updateVisibility = () => setVisible(documentVisible())

    document.addEventListener("visibilitychange", updateVisibility)
    updateVisibility()

    return () => document.removeEventListener("visibilitychange", updateVisibility)
  }, [])

  return visible
}
