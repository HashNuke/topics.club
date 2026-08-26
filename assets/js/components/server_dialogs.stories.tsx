import {EditServerDialog, LabeledInput, LeaveServerDialog, ManualJoinDialog} from "./server_dialogs.tsx"

export default {
  title: "Servers/Dialogs",
  parameters: {layout: "fullscreen"},
}

export const ManualJoin = {
  render: () => <ManualJoinDialog onClose={() => {}} onJoin={() => {}} />,
}

export const ManualJoinAdvanced = {
  render: () => <ManualJoinDialog initialAdvancedOpen onClose={() => {}} onJoin={() => {}} />,
}

export const EditServer = {
  render: () => (
    <EditServerDialog
      onClose={() => {}}
      onSave={() => {}}
      server={{id: "server:1", server_connection_id: 1, host: "irc.example.net", nickname: "mira", port: 6697, use_tls: true, mention_notifications_enabled: true, notification_preference_revision: 0, channels: []}}
    />
  ),
}

export const LeaveServer = {
  render: () => <LeaveServerDialog onClose={() => {}} onConfirm={() => {}} server={{id: "server:1", server_connection_id: 1, name: "Libera Chat", host: "irc.libera.chat", mention_notifications_enabled: true, notification_preference_revision: 0, channels: []}} />,
}

export const InputField = {
  decorators: [(Story: React.ComponentType) => <div className="mx-auto mt-12 w-80"><Story /></div>],
  render: () => <LabeledInput id="storybook-server-name" label="Server" value="irc.example.net" onChange={() => {}} />,
}
