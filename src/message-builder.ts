// Build the stream-json user message sent to the Claude CLI subprocess.
//
// CRITICAL: filter empty text blocks. The Claude CLI auto-applies cache_control
// to the last content block of each message as a cache breakpoint, and the
// Anthropic API rejects cache_control on empty text with:
//   "cache_control cannot be set for empty text blocks"
// An empty text block is also meaningless to the model — drop it unconditionally.

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

/**
 * Extract the latest user turn from a v3 prompt and serialize it as a Claude
 * stream-json `user` message. Everything before the last assistant turn is
 * assumed to already be in the CLI's session state (we spawn once per session).
 */
export function buildClaudeUserMessage(prompt: any[]): string {
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

/**
 * Extract a system prompt from the v3 prompt, if any. Returned as a single
 * string (concatenated) or undefined. Used to set `--system-prompt` at CLI
 * spawn time so OpenCode agent prompts actually reach the model.
 */
export function extractSystemPrompt(prompt: any[]): string | undefined {
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
