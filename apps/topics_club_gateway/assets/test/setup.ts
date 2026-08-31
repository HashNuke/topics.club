import "@testing-library/jest-dom/vitest"
import {afterEach, vi} from "vitest"
import {cleanup} from "@testing-library/react"

afterEach(() => {
  cleanup()
  window.history.replaceState(null, "", "/")
  localStorage.clear()
  vi.restoreAllMocks()
})
