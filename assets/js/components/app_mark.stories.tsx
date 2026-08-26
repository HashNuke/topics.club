import AppMark from "./app_mark.tsx"

export default {
  title: "Brand/AppMark",
  component: AppMark,
  args: {
    small: false,
  },
  argTypes: {
    small: {control: "boolean"},
  },
}

export const Default = {}

export const Small = {
  args: {
    small: true,
  },
}
