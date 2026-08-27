import {describe, expect, test} from "vitest"
import {approximateUserCount} from "./discovery_channel_card.tsx"

describe("approximateUserCount", () => {
  test.each([
    [0, "0"],
    [7, "7+"],
    [48, "40+"],
    [134, "100+"],
    [999, "900+"],
    [1_842, "1k+"],
    [9_453, "9k+"],
    [94_530, "90k+"],
    [1_945_300, "1m+"],
  ])("floors %i to %s", (count, estimate) => {
    expect(approximateUserCount(count)).toBe(estimate)
  })
})
