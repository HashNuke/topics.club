import {EditServerDialog, LabeledInput, LeaveServerDialog, ManualJoinDialog} from "./server_dialogs.jsx"

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
      server={{host: "irc.example.net", nickname: "mira", port: 6697, use_tls: true}}
    />
  ),
}

export const LeaveServer = {
  render: () => <LeaveServerDialog onClose={() => {}} onConfirm={() => {}} server={{name: "Libera Chat"}} />,
}

export const InputField = {
  decorators: [(Story) => <div className="mx-auto mt-12 w-80"><Story /></div>],
  render: () => <LabeledInput id="storybook-server-name" label="Server" value="irc.example.net" onChange={() => {}} />,
}
