export type BackgroundTask = { id: string; kind: string; label: string; startedAt: number }

declare module 'claude-code' {
  interface PluginState {
    'agent-status': {
      shown: 'working' | 'running' | 'ask' | 'done' | 'failed' | null
      tasks: BackgroundTask[]
      isExpanded: boolean
      now: number
    }
  }
}
