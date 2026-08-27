import React from "react"
import {render} from "@testing-library/react"
import {afterEach, describe, expect, test} from "vitest"
import MobileDrawer from "./mobile_drawer.tsx"

afterEach(() => {
  document.documentElement.style.overflow = ""
  document.documentElement.style.overscrollBehavior = ""
  document.body.style.overflow = ""
  document.body.style.overscrollBehavior = ""
})

describe("MobileDrawer", () => {
  test("locks document scrolling while open and restores it when closed", () => {
    document.documentElement.style.overflow = "auto"
    document.documentElement.style.overscrollBehavior = "contain"
    document.body.style.overflow = "scroll"
    document.body.style.overscrollBehavior = "auto"

    const {unmount} = render(
      <MobileDrawer onClose={() => {}} side="left">
        <div>Drawer content</div>
      </MobileDrawer>
    )

    expect(document.documentElement.style.overflow).toBe("hidden")
    expect(document.documentElement.style.overscrollBehavior).toBe("none")
    expect(document.body.style.overflow).toBe("hidden")
    expect(document.body.style.overscrollBehavior).toBe("none")

    unmount()

    expect(document.documentElement.style.overflow).toBe("auto")
    expect(document.documentElement.style.overscrollBehavior).toBe("contain")
    expect(document.body.style.overflow).toBe("scroll")
    expect(document.body.style.overscrollBehavior).toBe("auto")
  })
})
