import {mergeConfig} from "vite"
import tailwindcss from "@tailwindcss/vite"

export default {
  stories: ["../js/**/*.stories.@(js|jsx)"],
  framework: "@storybook/react-vite",
  addons: [],
  async viteFinal(config) {
    return mergeConfig(config, {
      plugins: [tailwindcss()],
    })
  },
}
