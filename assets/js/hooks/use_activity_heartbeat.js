import {useEffect} from "react"

export default function useActivityHeartbeat(apiClient, enabled) {
  useEffect(() => {
    if (!enabled || !apiClient.activity) return

    const touchActivity = () => {
      apiClient.activity().catch(() => {})
    }
    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") touchActivity()
    }

    touchActivity()
    document.addEventListener("visibilitychange", handleVisibilityChange)
    window.addEventListener("focus", touchActivity)
    const interval = window.setInterval(touchActivity, 30 * 60 * 1000)

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange)
      window.removeEventListener("focus", touchActivity)
      window.clearInterval(interval)
    }
  }, [apiClient, enabled])
}
