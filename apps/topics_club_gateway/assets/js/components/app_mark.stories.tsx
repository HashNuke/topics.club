import AppMark from "./app_mark.tsx"

export default {
  title: "Brand/Wordmark",
  component: AppMark,
  decorators: [(Story: React.ComponentType) => <div className="rounded-xl border border-white/8 bg-[var(--app-sidebar)] p-6"><Story /></div>],
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
