// Per-session process/session-id tracking. One key per (cwd, modelId) so the
// same working directory can have independent sonnet / opus / haiku sessions.

import type { ChildProcess } from "node:child_process"
import type { EventEmitter } from "node:events"

export interface ActiveProcess {
  proc: ChildProcess
  lineEmitter: EventEmitter
}

const activeProcesses = new Map<string, ActiveProcess>()
const claudeSessions = new Map<string, string>()

export function sessionKey(cwd: string, modelId: string): string {
  return `${cwd}::${modelId}`
}

export function getActiveProcess(key: string): ActiveProcess | undefined {
  return activeProcesses.get(key)
}

export function setActiveProcess(key: string, ap: ActiveProcess): void {
  activeProcesses.set(key, ap)
}

export function deleteActiveProcess(key: string): void {
  const ap = activeProcesses.get(key)
  if (!ap) return
  try {
    ap.proc.kill()
  } catch {
    /* ignore */
  }
  activeProcesses.delete(key)
}

export function getClaudeSessionId(key: string): string | undefined {
  return claudeSessions.get(key)
}

export function setClaudeSessionId(key: string, sid: string): void {
  claudeSessions.set(key, sid)
}

export function deleteClaudeSessionId(key: string): void {
  claudeSessions.delete(key)
}
