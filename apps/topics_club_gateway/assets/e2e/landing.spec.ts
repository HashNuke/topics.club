import {expect, test} from "@playwright/test"

test("landing page lists only local IRC server topics", async ({page}) => {
  await page.goto("/")

  await expect(page.getByText("topics.club")).toBeVisible()
  await expect(page.getByRole("heading", {name: "Community chat"})).toBeVisible()
  await expect(page.getByRole("link", {name: "Developer OAuth"})).toHaveAttribute("href", "/auth/developer")
  await expect(page.getByRole("button", {name: /#elixir/})).toContainText("on 127.0.0.1")
  await expect(page.getByRole("button", {name: /#phoenix/})).toContainText("on 127.0.0.1")
  await expect(page.getByText("irc.libera.chat")).toHaveCount(0)
  await expect(page.getByText("irc.oftc.net")).toHaveCount(0)
})

test("chat route requires authentication", async ({page}) => {
  await page.goto("/chat")

  await expect(page).toHaveURL(/\/users\/log-in/)
})
