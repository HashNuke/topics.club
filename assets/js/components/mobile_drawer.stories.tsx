import MobileDrawer, {MobileDrawerHeader} from "./mobile_drawer.tsx"
import type {ComponentProps} from "react"

type DrawerArgs = ComponentProps<typeof MobileDrawer>

export default {
  title: "Navigation/MobileDrawer",
  component: MobileDrawer,
  parameters: {layout: "fullscreen", viewport: {defaultViewport: "mobile1"}},
  args: {onClose: () => {}, side: "left"},
}

export const Channels = {
  render: (args: DrawerArgs) => <MobileDrawer {...args}><MobileDrawerHeader title="Channels" onClose={args.onClose} /><div className="space-y-2 p-4 text-sm text-slate-300"><div>#elixir</div><div>#phoenix</div><div>#music</div></div></MobileDrawer>,
}

export const People = {
  args: {side: "right"},
  render: (args: DrawerArgs) => <MobileDrawer {...args}><MobileDrawerHeader title="People" onClose={args.onClose} /><div className="space-y-2 p-4 text-sm text-slate-300"><div>mira</div><div>akash</div><div>lena</div></div></MobileDrawer>,
}
