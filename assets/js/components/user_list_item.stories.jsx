import UserListItem from "./user_list_item.tsx"

export default {
  title: "People/UserListItem",
  component: UserListItem,
  decorators: [(Story) => <div className="w-64 max-w-full"><Story /></div>],
  args: {
    user: {nick: "mira", role: "user", status: "online"},
  },
}

export const Online = {}

export const Away = {
  args: {user: {nick: "akash", role: "user", status: "away"}},
}

export const Moderator = {
  args: {user: {nick: "lena", role: "op", status: "online"}},
}

export const Voiced = {
  args: {user: {nick: "robin", role: "voice", status: "online"}},
}

export const LongNickname = {
  args: {user: {nick: "a_very_long_irc_nickname_that_truncates", role: "halfop", status: "online"}},
}
