import {defineConfig, devices} from "@playwright/test"

export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  expect: {
    timeout: 10_000,
  },
  use: {
    baseURL: "http://127.0.0.1:4002",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"]},
    },
  ],
  webServer: {
    command:
      "cd .. && MIX_ENV=test mix ecto.create --quiet -r Ircpipe.Repo && MIX_ENV=test mix ecto.migrate --quiet -r Ircpipe.Repo && MIX_ENV=test mix run priv/repo/seeds.exs && mix assets.build && MIX_ENV=test PHX_SERVER=true mix phx.server",
    url: "http://127.0.0.1:4002",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
