import {fireEvent, render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import ChannelDirectoryPagination from "./channel_directory_pagination.tsx"

describe("ChannelDirectoryPagination", () => {
  test("moves through fixed 25-channel pages", () => {
    const onPageChange = vi.fn()

    render(
      <ChannelDirectoryPagination
        ariaLabel="Channel pages"
        onPageChange={onPageChange}
        page={2}
        pageSize={25}
        totalChannels={53}
        totalPages={3}
      />
    )

    expect(screen.getByText(/Showing/)).toHaveTextContent("Showing 26–50 of 53 channels")
    expect(screen.getByText("Page 2 of 3")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", {name: "Previous channel page"}))
    fireEvent.click(screen.getByRole("button", {name: "Next channel page"}))

    expect(onPageChange.mock.calls).toEqual([[1], [3]])
  })
})
