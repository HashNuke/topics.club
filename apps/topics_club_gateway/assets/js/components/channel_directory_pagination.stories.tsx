import ChannelDirectoryPagination from "./channel_directory_pagination.tsx"

export default {
  title: "Directory/ChannelDirectoryPagination",
  component: ChannelDirectoryPagination,
  decorators: [(Story: React.ComponentType) => <div className="w-[52rem] max-w-[calc(100vw-2rem)] rounded-lg border border-slate-800 bg-[var(--app-panel)]"><Story /></div>],
  args: {
    ariaLabel: "Channel directory pagination",
    onPageChange: () => {},
    page: 2,
    pageSize: 25,
    totalChannels: 418,
    totalPages: 17,
  },
}

export const MiddlePage = {}

export const FirstPage = {
  args: {page: 1},
}

export const LastPage = {
  args: {page: 17},
}

export const MobileWidth = {
  decorators: [(Story: React.ComponentType) => <div className="w-80 max-w-full rounded-lg border border-slate-800 bg-[var(--app-panel)]"><Story /></div>],
}
