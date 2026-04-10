const DEBUG = process.env.DEBUG?.includes("claude-proxy") ?? false

function fmt(level: string, msg: string, data?: Record<string, unknown>): string {
  const ts = new Date().toISOString()
  const base = `[${ts}] [claude-proxy] ${level}: ${msg}`
  if (data && Object.keys(data).length > 0) return `${base} ${safeJson(data)}`
  return base
}

function safeJson(data: unknown): string {
  try {
    return JSON.stringify(data)
  } catch {
    return String(data)
  }
}

export const log = {
  info(msg: string, data?: Record<string, unknown>) {
    if (DEBUG) console.error(fmt("INFO", msg, data))
  },
  warn(msg: string, data?: Record<string, unknown>) {
    if (DEBUG) console.error(fmt("WARN", msg, data))
  },
  error(msg: string, data?: Record<string, unknown>) {
    console.error(fmt("ERROR", msg, data))
  },
  debug(msg: string, data?: Record<string, unknown>) {
    if (DEBUG) console.error(fmt("DEBUG", msg, data))
  },
}
