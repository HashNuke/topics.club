export interface CommandError {
  error?: {
    message?: string
    usage?: string
  }
  reason?: string
}

export function isStaleDirectMessageError(error: unknown): boolean {
  return Boolean(
    error &&
    typeof error === "object" &&
    "reason" in error &&
    error.reason === "stale_direct_message"
  )
}

export function commandErrorMessage(error: CommandError | null | undefined): string {
  if (error?.error?.message) {
    const usage = error.error.usage ? ` Usage: ${error.error.usage}` : ""
    return `${error.error.message}${usage}`
  }

  const messages: Record<string, string> = {
    invalid_buffer: "That IRC buffer is no longer available.",
    invalid_command_args: "The command arguments are incomplete or invalid.",
    joining_channel: "Wait for the channel join to finish, then try again.",
    not_connected: "Reconnect to the IRC server before running this command.",
    not_joined: "Join that channel before sending to it.",
    unknown_command: "That slash command is not supported.",
  }

  return (error?.reason && messages[error.reason]) || "The IRC command could not be sent."
}

export function channelDirectoryError(reason?: string): string {
  if (reason === "list_in_progress") return "This server is already preparing a channel list. Try again in a moment."
  if (reason === "list_timeout") return "The server took too long to return its channel list."
  if (reason === "not_connected") return "Reconnect to this server before browsing its channels."
  return "The server could not return its channel list. Try again shortly."
}
