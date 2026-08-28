import {useState} from "react"
import UserGroup from "./user_group.tsx"
import type {ComponentProps} from "react"

const users = Array.from({length: 13}, (_, index) => ({
  nick: `member_${index + 1}`,
  nick_key: `member_${index + 1}`,
  role: "user",
  status: index === 4 ? "away" : "online",
}))

type UserGroupArgs = ComponentProps<typeof UserGroup>

function ExpandableGroup(args: UserGroupArgs) {
  const [expanded, setExpanded] = useState(args.expanded)
  return <UserGroup {...args} expanded={expanded} onExpand={() => setExpanded(true)} />
}

export default {
  title: "People/UserGroup",
  component: UserGroup,
  render: (args: UserGroupArgs) => <ExpandableGroup {...args} />,
  decorators: [(Story: React.ComponentType) => <div className="w-64 max-w-full"><Story /></div>],
  args: {expanded: false, label: "Online", users},
}

export const Collapsed = {}

export const Expanded = {
  args: {expanded: true},
}

export const Moderators = {
  args: {
    label: "Mods",
    users: [
      {nick: "mira", nick_key: "mira", role: "owner", status: "online"},
      {nick: "akash", nick_key: "akash", role: "op", status: "online"},
      {nick: "lena", nick_key: "lena", role: "halfop", status: "away"},
    ],
  },
}
