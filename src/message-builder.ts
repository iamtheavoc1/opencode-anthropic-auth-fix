// Build the stream-json user message sent to the Claude CLI subprocess.
//
// CRITICAL #1: filter empty text blocks. The Claude CLI auto-applies
// cache_control to the last content block of each message as a cache
// breakpoint, and the Anthropic API rejects cache_control on empty text with:
//   "cache_control cannot be set for empty text blocks"
// An empty text block is also meaningless to the model — drop it unconditionally.
//
// CRITICAL #2: do NOT pass `--system-prompt` to the CLI. Overriding the default
// Claude Code system prompt makes Anthropic bill the request against the
// "extra usage" pool instead of the Claude Code subscription pool, producing
// `out of extra usage` 400s even on accounts with interactive headroom. Any
// system prompt OpenCode supplies is inlined into the user turn here instead
// so the CLI's default Claude Code prompt stays intact.

type ClaudeTextBlock = { type: "text"; text: string }
type ClaudeToolResultBlock = {
  type: "tool_result"
  tool_use_id: string
  content: string
}
type ClaudeBlock = ClaudeTextBlock | ClaudeToolResultBlock

function stringifyToolResult(result: unknown): string {
  if (typeof result === "string") return result
  if (Array.isArray(result)) {
    return result
      .filter((p: any) => p && p.type === "text" && typeof p.text === "string")
      .map((p: any) => p.text)
      .join("\n")
  }
  if (result && typeof result === "object") {
    const r = result as Record<string, unknown>
    if ("output" in r) return String(r.output)
    try {
      return JSON.stringify(r)
    } catch {
      return String(r)
    }
  }
  return ""
}

function extractSystemText(prompt: any[]): string | undefined {
  const parts: string[] = []
  for (const msg of prompt) {
    if (msg.role !== "system") continue
    if (typeof msg.content === "string") {
      if (msg.content.trim()) parts.push(msg.content)
    } else if (Array.isArray(msg.content)) {
      for (const p of msg.content) {
        if (p.type === "text" && typeof p.text === "string" && p.text.trim()) {
          parts.push(p.text)
        }
      }
    }
  }
  if (parts.length === 0) return undefined
  return parts.join("\n\n")
}

export interface BuildMessageOptions {
  /**
   * When true, any `system` messages in the prompt are inlined as a
   * `<context>…</context>` prefix on the first text block of the user turn.
   * The caller sets this only on the FIRST turn of a newly-spawned CLI
   * subprocess so subsequent turns don't re-send the same context.
   */
  includeSystemPrefix?: boolean
}

/**
 * Extract the latest user turn from a v3 prompt and serialize it as a Claude
 * stream-json `user` message. Everything before the last assistant turn is
 * assumed to already be in the CLI's session state (we spawn once per session).
 */
export function buildClaudeUserMessage(
  prompt: any[],
  opts: BuildMessageOptions = {},
): string {
  // Find the slice after the last assistant message — that's "the current turn".
  let startIdx = 0
  for (let i = prompt.length - 1; i >= 0; i--) {
    if (prompt[i].role === "assistant") {
      startIdx = i + 1
      break
    }
  }

  const content: ClaudeBlock[] = []

  for (let i = startIdx; i < prompt.length; i++) {
    const msg = prompt[i]
    if (msg.role !== "user" && msg.role !== "tool") continue

    if (typeof msg.content === "string") {
      const t = msg.content
      if (t.trim()) content.push({ type: "text", text: t })
      continue
    }

    if (!Array.isArray(msg.content)) continue

    for (const part of msg.content) {
      if (part.type === "text") {
        if (typeof part.text === "string" && part.text.trim()) {
          content.push({ type: "text", text: part.text })
        }
        continue
      }

      if (part.type === "tool-result") {
        // v3 tool-result shape: { toolCallId, toolName, result, ... }
        const resultText = stringifyToolResult(part.result)
        // Empty tool_result can also trip cache_control; pad with a single space.
        content.push({
          type: "tool_result",
          tool_use_id: part.toolCallId,
          content: resultText.length > 0 ? resultText : " ",
        })
      }
      // Ignore file parts, reasoning parts, and anything else — the CLI doesn't
      // accept them on its stdin stream-json input.
    }
  }

  // Inline system prompt as a prefix on the FIRST text block of the very first
  // turn of a session. The CLI's default Claude Code system prompt stays
  // intact — critical so the request bills against the Claude Code pool
  // instead of the extra-usage pool.
  if (opts.includeSystemPrefix) {
    const systemText = extractSystemText(prompt)
    if (systemText) {
      const header = `<context>\n${systemText}\n</context>\n\n`
      const firstTextIdx = content.findIndex((b) => b.type === "text")
      if (firstTextIdx >= 0) {
        const existing = content[firstTextIdx] as ClaudeTextBlock
        content[firstTextIdx] = { type: "text", text: header + existing.text }
      } else {
        content.unshift({ type: "text", text: header.trimEnd() })
      }
    }
  }

  // Guarantee at least one non-empty content block so cache_control lands on
  // something valid.
  if (content.length === 0) {
    content.push({ type: "text", text: " " })
  }

  return JSON.stringify({
    type: "user",
    message: { role: "user", content },
  })
}
