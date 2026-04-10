// ClaudeProxyLanguageModel
//
// Implements AI SDK v3 LanguageModelV3 by spawning the `claude` CLI binary
// in stream-json mode and translating its Anthropic-style output stream into
// v3 stream parts. The process is kept alive per (cwd, modelId) across turns
// so the CLI's in-memory session state is reused.
//
// Key invariants:
// - specificationVersion is "v3".
// - usage is always nested V3Usage, never raw numbers. Never crashes on
//   missing/undefined fields.
// - No empty text blocks are ever sent to the CLI (see message-builder).
// - finishReason is the nested v3 shape { unified, raw }.

import { spawn } from "node:child_process"
import { createInterface } from "node:readline"
import { EventEmitter } from "node:events"

import { log } from "./logger.ts"
import { mapTool } from "./tool-mapping.ts"
import { buildClaudeUserMessage, extractSystemPrompt } from "./message-builder.ts"
import {
  deleteActiveProcess,
  deleteClaudeSessionId,
  getActiveProcess,
  getClaudeSessionId,
  sessionKey,
  setActiveProcess,
  setClaudeSessionId,
  type ActiveProcess,
} from "./session-manager.ts"
import { EMPTY_USAGE, toV3Usage, type V3Usage } from "./usage.ts"

function generateId(): string {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36)
}

export interface ClaudeProxyConfig {
  /** Provider name as seen by OpenCode (e.g. "claude-proxy"). */
  name: string
  /** Path to the `claude` CLI binary. Falls back to $CLAUDE_CLI_PATH or "claude". */
  cliPath?: string
  /** Working directory for the CLI subprocess. Defaults to process.cwd(). */
  cwd?: string
  /** Pass --dangerously-skip-permissions to the CLI. Defaults to true. */
  skipPermissions?: boolean
}

interface SpawnOptions {
  sk: string
  systemPrompt: string | undefined
  resumeSessionId: string | undefined
}

export class ClaudeProxyLanguageModel {
  readonly specificationVersion = "v3" as const
  readonly modelId: string
  readonly config: Required<Omit<ClaudeProxyConfig, "cwd">> & { cwd: string }
  readonly supportedUrls = {}

  constructor(modelId: string, config: ClaudeProxyConfig) {
    this.modelId = modelId
    this.config = {
      name: config.name,
      cliPath: config.cliPath ?? process.env.CLAUDE_CLI_PATH ?? "claude",
      cwd: config.cwd ?? process.cwd(),
      skipPermissions: config.skipPermissions ?? true,
    }
  }

  get provider(): string {
    return this.config.name
  }

  // ── Process management ───────────────────────────────────────────────

  private buildCliArgs(opts: SpawnOptions): string[] {
    const args = [
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--verbose",
      "--model",
      this.modelId,
    ]
    if (opts.resumeSessionId) args.push("--session-id", opts.resumeSessionId)
    if (opts.systemPrompt) args.push("--system-prompt", opts.systemPrompt)
    if (this.config.skipPermissions) args.push("--dangerously-skip-permissions")
    return args
  }

  private spawnProcess(opts: SpawnOptions): ActiveProcess {
    const args = this.buildCliArgs(opts)
    log.info("spawn", { cli: this.config.cliPath, args, cwd: this.config.cwd, sk: opts.sk })

    let proc
    try {
      proc = spawn(this.config.cliPath, args, {
        cwd: this.config.cwd,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, TERM: "xterm-256color" },
      })
    } catch (err: any) {
      throw new Error(
        `claude-proxy: failed to spawn '${this.config.cliPath}' — ${err?.message ?? err}. ` +
          `Is the Claude CLI installed and on PATH? Set CLAUDE_CLI_PATH to override.`,
      )
    }

    if (!proc.pid) {
      throw new Error(
        `claude-proxy: spawned '${this.config.cliPath}' but got no PID. ` +
          `Is the binary executable?`,
      )
    }

    const lineEmitter = new EventEmitter()
    const rl = createInterface({ input: proc.stdout! })
    rl.on("line", (line) => lineEmitter.emit("line", line))
    rl.on("close", () => lineEmitter.emit("close"))

    proc.on("exit", (code, signal) => {
      log.info("exit", { code, signal, sk: opts.sk })
      deleteActiveProcess(opts.sk)
      if (code !== 0 && code !== null) {
        deleteClaudeSessionId(opts.sk)
      }
    })

    proc.stderr?.on("data", (data) => {
      const s = data.toString()
      log.debug("stderr", { s: s.slice(0, 300) })
      if (
        s.includes("Session ID") &&
        (s.includes("already in use") || s.includes("not found") || s.includes("invalid"))
      ) {
        deleteClaudeSessionId(opts.sk)
      }
    })

    const ap: ActiveProcess = { proc, lineEmitter }
    setActiveProcess(opts.sk, ap)
    return ap
  }

  // ── Public API ───────────────────────────────────────────────────────

  async doStream(options: any): Promise<any> {
    const self = this
    const warnings: any[] = []
    const sk = sessionKey(self.config.cwd, self.modelId)

    // A brand-new conversation — clear any stale session state.
    const hasPriorConversation =
      options.prompt.filter((m: any) => m.role === "user" || m.role === "assistant").length > 1
    if (!hasPriorConversation) {
      deleteClaudeSessionId(sk)
      deleteActiveProcess(sk)
    }

    const systemPrompt = extractSystemPrompt(options.prompt)
    const userMsg = buildClaudeUserMessage(options.prompt)

    const stream = new ReadableStream({
      start(controller) {
        let ap = getActiveProcess(sk)
        if (!ap) {
          try {
            ap = self.spawnProcess({
              sk,
              systemPrompt,
              resumeSessionId: getClaudeSessionId(sk),
            })
          } catch (err) {
            controller.enqueue({ type: "stream-start", warnings })
            controller.enqueue({ type: "error", error: err })
            controller.enqueue({
              type: "finish",
              finishReason: { unified: "error", raw: "spawn-failed" },
              usage: EMPTY_USAGE,
            })
            try {
              controller.close()
            } catch {
              /* ignore */
            }
            return
          }
        }
        const { proc, lineEmitter } = ap

        controller.enqueue({ type: "stream-start", warnings })

        const textId = generateId()
        let textStarted = false
        const reasoningIds = new Map<number, string>()
        const toolCallMap = new Map<number, { id: string; name: string; inputJson: string }>()
        const toolCallsById = new Map<string, { id: string; name: string; input: any }>()
        let controllerClosed = false
        let finishEmitted = false
        let resultMeta: Record<string, unknown> = {}
        let latestUsage: any = null

        const detach = () => {
          lineEmitter.off("line", lineHandler)
          lineEmitter.off("close", closeHandler)
          proc.off("error", procErrorHandler)
        }

        const closeController = () => {
          if (controllerClosed) return
          controllerClosed = true
          detach()
          try {
            controller.close()
          } catch {
            /* ignore */
          }
        }

        const emitFinish = (reason: "stop" | "tool-calls" | "error") => {
          if (finishEmitted) return
          finishEmitted = true
          if (textStarted) {
            try {
              controller.enqueue({ type: "text-end", id: textId })
            } catch {
              /* ignore */
            }
          }
          for (const [idx, rid] of reasoningIds) {
            try {
              controller.enqueue({ type: "reasoning-end", id: rid })
            } catch {
              /* ignore */
            }
            reasoningIds.delete(idx)
          }
          try {
            controller.enqueue({
              type: "finish",
              finishReason: { unified: reason, raw: reason },
              usage: toV3Usage(latestUsage),
              providerMetadata: { "claude-proxy": resultMeta },
            })
          } catch {
            /* ignore */
          }
        }

        const lineHandler = (line: string) => {
          if (!line.trim() || controllerClosed) return
          let msg: any
          try {
            msg = JSON.parse(line)
          } catch {
            return
          }
          log.debug("msg", { type: msg.type, subtype: msg.subtype })

          if (msg.type === "system" && msg.subtype === "init" && msg.session_id) {
            setClaudeSessionId(sk, msg.session_id)
          }

          // Streaming-style content blocks
          if (msg.type === "content_block_start" && msg.content_block && msg.index !== undefined) {
            const block = msg.content_block
            const idx = msg.index
            if (block.type === "thinking") {
              const rid = generateId()
              reasoningIds.set(idx, rid)
              controller.enqueue({ type: "reasoning-start", id: rid })
            }
            if (block.type === "text") {
              if (!textStarted) {
                controller.enqueue({ type: "text-start", id: textId })
                textStarted = true
              }
            }
            if (block.type === "tool_use" && block.id && block.name) {
              toolCallMap.set(idx, { id: block.id, name: block.name, inputJson: "" })
              const { name: mappedName, skip } = mapTool(block.name)
              if (!skip) {
                controller.enqueue({
                  type: "tool-input-start",
                  id: block.id,
                  toolName: mappedName,
                })
              }
            }
          }

          if (msg.type === "content_block_delta" && msg.delta && msg.index !== undefined) {
            const delta = msg.delta
            const idx = msg.index
            if (delta.type === "thinking_delta" && delta.thinking) {
              const rid = reasoningIds.get(idx)
              if (rid) {
                controller.enqueue({ type: "reasoning-delta", id: rid, delta: delta.thinking })
              }
            }
            if (delta.type === "text_delta" && delta.text) {
              if (!textStarted) {
                controller.enqueue({ type: "text-start", id: textId })
                textStarted = true
              }
              controller.enqueue({ type: "text-delta", id: textId, delta: delta.text })
            }
            if (delta.type === "input_json_delta" && delta.partial_json) {
              const tc = toolCallMap.get(idx)
              if (tc) {
                tc.inputJson += delta.partial_json
                controller.enqueue({
                  type: "tool-input-delta",
                  id: tc.id,
                  delta: delta.partial_json,
                })
              }
            }
          }

          if (msg.type === "content_block_stop" && msg.index !== undefined) {
            const idx = msg.index
            const rid = reasoningIds.get(idx)
            if (rid) {
              controller.enqueue({ type: "reasoning-end", id: rid })
              reasoningIds.delete(idx)
            }
            const tc = toolCallMap.get(idx)
            if (tc) {
              controller.enqueue({ type: "tool-input-end", id: tc.id })
              let parsedInput: any = {}
              try {
                parsedInput = JSON.parse(tc.inputJson || "{}")
              } catch {
                /* ignore */
              }
              const { name: mappedName, input: mappedInput, executed, skip } = mapTool(
                tc.name,
                parsedInput,
              )
              if (!skip) {
                toolCallsById.set(tc.id, { id: tc.id, name: tc.name, input: parsedInput })
                controller.enqueue({
                  type: "tool-call",
                  toolCallId: tc.id,
                  toolName: mappedName,
                  input: JSON.stringify(mappedInput),
                  providerExecuted: executed,
                })
              }
            }
          }

          // Non-streaming aggregated assistant messages
          if (msg.type === "assistant" && msg.message?.content) {
            for (const block of msg.message.content) {
              if (block.type === "text" && block.text) {
                if (!textStarted) {
                  controller.enqueue({ type: "text-start", id: textId })
                  textStarted = true
                }
                controller.enqueue({ type: "text-delta", id: textId, delta: block.text })
              }
              if (block.type === "thinking" && block.thinking) {
                const rid = generateId()
                controller.enqueue({ type: "reasoning-start", id: rid })
                controller.enqueue({ type: "reasoning-delta", id: rid, delta: block.thinking })
                controller.enqueue({ type: "reasoning-end", id: rid })
              }
              if (block.type === "tool_use" && block.id && block.name) {
                const parsedInput = block.input ?? {}
                toolCallsById.set(block.id, {
                  id: block.id,
                  name: block.name,
                  input: parsedInput,
                })
                const { name: mappedName, input: mappedInput, executed, skip } = mapTool(
                  block.name,
                  parsedInput,
                )
                if (!skip) {
                  controller.enqueue({
                    type: "tool-input-start",
                    id: block.id,
                    toolName: mappedName,
                  })
                  controller.enqueue({
                    type: "tool-call",
                    toolCallId: block.id,
                    toolName: mappedName,
                    input: JSON.stringify(mappedInput),
                    providerExecuted: executed,
                  })
                }
              }
            }
            if (msg.message.usage) latestUsage = msg.message.usage
          }

          // Tool results (provider-executed)
          if (msg.type === "user" && msg.message?.content) {
            for (const block of msg.message.content) {
              if (block.type === "tool_result" && block.tool_use_id) {
                const tc = toolCallsById.get(block.tool_use_id)
                if (!tc) continue
                let resultText = ""
                if (typeof block.content === "string") {
                  resultText = block.content
                } else if (Array.isArray(block.content)) {
                  resultText = block.content
                    .filter((c: any) => c.type === "text" && typeof c.text === "string")
                    .map((c: any) => c.text)
                    .join("\n")
                }
                controller.enqueue({
                  type: "tool-result",
                  toolCallId: block.tool_use_id,
                  toolName: tc.name,
                  result: { output: resultText, title: tc.name, metadata: {} },
                  providerExecuted: true,
                })
                toolCallsById.delete(block.tool_use_id)
              }
            }
          }

          // End of conversation turn
          if (msg.type === "result") {
            if (msg.session_id) setClaudeSessionId(sk, msg.session_id)
            resultMeta = {
              sessionId: msg.session_id ?? null,
              costUsd: msg.total_cost_usd ?? null,
              durationMs: msg.duration_ms ?? null,
            }
            if (msg.usage) latestUsage = msg.usage

            if (msg.is_error) {
              const errText = msg.error_text ?? msg.error?.message ?? "Claude CLI reported an error"
              controller.enqueue({ type: "error", error: new Error(errText) })
              emitFinish("error")
            } else {
              emitFinish(toolCallMap.size > 0 ? "tool-calls" : "stop")
            }
            closeController()
          }
        }

        const closeHandler = () => {
          if (controllerClosed) return
          // Stream ended without a result line — still emit finish so consumers
          // don't hang.
          emitFinish("stop")
          closeController()
        }

        const procErrorHandler = (err: Error) => {
          log.error("proc.error", { message: err.message })
          if (controllerClosed) return
          try {
            controller.enqueue({ type: "error", error: err })
          } catch {
            /* ignore */
          }
          emitFinish("error")
          closeController()
        }

        lineEmitter.on("line", lineHandler)
        lineEmitter.on("close", closeHandler)
        proc.on("error", procErrorHandler)

        if (options.abortSignal) {
          options.abortSignal.addEventListener("abort", () => {
            if (controllerClosed) return
            emitFinish("error")
            closeController()
          })
        }

        try {
          proc.stdin!.write(userMsg + "\n")
        } catch (err: any) {
          log.error("stdin.write", { message: err?.message })
          controller.enqueue({ type: "error", error: err })
          emitFinish("error")
          closeController()
        }
      },
      cancel() {
        /* Process is kept alive for session reuse; explicit cancel is a no-op. */
      },
    })

    return {
      stream,
      request: { body: { text: userMsg } },
      response: { headers: {} },
    }
  }

  async doGenerate(options: any): Promise<any> {
    // Collect the stream into a single non-streaming result.
    const { stream, request, response } = await this.doStream(options)
    const reader = (stream as ReadableStream<any>).getReader()

    let text = ""
    let reasoning = ""
    const toolCalls: any[] = []
    let finishReason: any = { unified: "stop", raw: "stop" }
    let usage: V3Usage = EMPTY_USAGE
    let providerMetadata: any = {}
    let firstError: unknown = null

    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      switch (value.type) {
        case "text-delta":
          text += value.delta
          break
        case "reasoning-delta":
          reasoning += value.delta
          break
        case "tool-call":
          toolCalls.push(value)
          break
        case "finish":
          finishReason = value.finishReason
          usage = value.usage
          providerMetadata = value.providerMetadata ?? {}
          break
        case "error":
          if (!firstError) firstError = value.error
          break
      }
    }

    if (firstError) throw firstError

    const content: any[] = []
    if (reasoning) content.push({ type: "reasoning", text: reasoning })
    if (text) content.push({ type: "text", text })
    for (const tc of toolCalls) {
      let parsedInput = tc.input
      if (typeof parsedInput === "string") {
        try {
          parsedInput = JSON.parse(parsedInput)
        } catch {
          /* keep as-is */
        }
      }
      content.push({
        type: "tool-call",
        toolCallId: tc.toolCallId,
        toolName: tc.toolName,
        input: parsedInput,
        providerExecuted: tc.providerExecuted,
      })
    }

    return {
      content,
      finishReason,
      usage,
      providerMetadata,
      warnings: [],
      request,
      response: {
        ...response,
        id: generateId(),
        timestamp: new Date(),
        modelId: this.modelId,
      },
    }
  }
}
