import {mergeConfig} from "vite"
import tailwindcss from "@tailwindcss/vite"
import type {StorybookConfig} from "@storybook/react-vite"

const config: StorybookConfig = {
  stories: ["../js/**/*.stories.@(ts|tsx)"],
  framework: "@storybook/react-vite",
  addons: [],
  async viteFinal(config) {
    return mergeConfig(config, {
      plugins: [tailwindcss()],
    })
  },
}

export default config
