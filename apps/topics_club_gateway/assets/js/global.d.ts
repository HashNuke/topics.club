declare module "phoenix" {
  interface ReceiveChain {
    receive(status: "ok" | "error" | "timeout", callback: (payload: Record<string, unknown>) => void): ReceiveChain
  }

  interface Channel {
    on(event: string, callback: (payload: Record<string, unknown>) => void): void
    join(): ReceiveChain
    push(event: string, payload: Record<string, unknown>, timeout: number): ReceiveChain
    leave(): void
  }

  export class Socket {
    constructor(path: string, options: {longPollFallbackMs: number; params: {_csrf_token?: string | null}})
    channel(topic: string, params: Record<string, unknown>): Channel
    connect(): void
    disconnect(): void
    connectionState(): string
    onOpen(callback: () => void): void
    onClose(callback: (event: unknown) => void): void
    onError(callback: (error: unknown) => void): void
  }
}

declare module "phoenix-colocated/topics_club_gateway" {
  export const hooks: Record<string, any>
}

interface LiveReloader {
  enableServerLogs(): void
  openEditorAtCaller(target: EventTarget | null): void
  openEditorAtDef(target: EventTarget | null): void
}

interface Window {
  liveSocket: unknown
  liveReloader: LiveReloader
}

declare const process: {
  env: {CI?: string; NODE_ENV?: string}
}

declare module "*.css"
