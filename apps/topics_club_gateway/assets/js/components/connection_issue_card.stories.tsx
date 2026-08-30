import ConnectionIssueCard from "./connection_issue_card.tsx"
import type {ConnectionIssue} from "../connection_issue.ts"
import type {ServerConnection} from "../types.ts"

const server: ServerConnection = {
  id: "server:42",
  server_connection_id: 42,
  host: "irc.example.net",
  status: "errored",
  mention_notifications_enabled: true,
  notification_preference_revision: 0,
  channels: [],
}

const nicknameIssue: ConnectionIssue = {
  code: "invalid_nickname",
  title: "Nickname is not valid",
  summary: "The server rejected topics.club@example as an erroneous nickname.",
  edit_focus: "nickname",
  attempted_nickname: "topics.club@example",
  irc_code: "432",
}

export default {
  title: "Servers/ConnectionIssueCard",
  component: ConnectionIssueCard,
  args: {
    issue: nicknameIssue,
    onEditServer: () => {},
    onReconnectServer: () => {},
    server,
  },
  decorators: [
    (Story: React.ComponentType) => (
      <div className="mx-auto w-[48rem] max-w-[calc(100vw-2rem)] p-4">
        <Story />
      </div>
    ),
  ],
}

export const NicknameIssue = {}

export const AuthenticationIssue = {
  args: {
    issue: {
      code: "authentication_failed",
      title: "IRC account login failed",
      summary: "Check the IRC account name and password, then reconnect.",
      edit_focus: "credentials",
      irc_code: "904",
    },
  },
}

export const RetryLimitReached = {
  args: {
    issue: {
      code: "connection_failed",
      title: "Could not connect after 5 retries",
      summary: "Check the server address, port, TLS setting, or credentials before trying again.",
      edit_focus: "connection",
      technical_details: "{:tls_alert, {:unknown_ca, 'TLS client: In state certify'}}",
    },
  },
}

export const Mobile = {
  parameters: {viewport: {defaultViewport: "mobile1"}},
  decorators: [
    (Story: React.ComponentType) => (
      <div className="mx-auto w-80 max-w-full p-3">
        <Story />
      </div>
    ),
  ],
}
