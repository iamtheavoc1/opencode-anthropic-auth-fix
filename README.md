# opencode-claude-proxy

A local [OpenCode](https://opencode.ai) provider that routes Anthropic model
calls through the `claude` CLI binary instead of the Anthropic HTTP API. Your
Claude subscription (Pro / Max) pays for the tokens — no separate API credit
spend, no separate key.

It's a drop-in AI SDK v3 `LanguageModelV3` implementation. OpenCode loads it
like any other provider; the only difference is that under the hood it spawns
`claude --output-format stream-json --input-format stream-json`, pipes the
current turn in, and translates the CLI's Anthropic-style output stream back
into OpenCode's expected stream parts.

## Why

`opencode-claude-code-plugin` crashed on `undefined is not an object (evaluating 'usage.inputTokens.total')` because it declared `specificationVersion = "v2"` and returned flat usage numbers, while OpenCode now consumes AI SDK v3's nested `LanguageModelV3Usage` shape (`{ inputTokens: { total, noCache, cacheRead, cacheWrite }, outputTokens: { total, text, reasoning } }`). It also forwarded empty-text content blocks to the CLI, which tripped Anthropic's `cache_control cannot be set for empty text blocks` rejection as soon as the CLI tried to apply a cache breakpoint to them.

This rewrite fixes both at the source:

| Issue                                                   | Fix                                                                                                                                                       |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `usage.inputTokens.total` crash                         | Implements `specificationVersion = "v3"` and always emits nested `LanguageModelV3Usage`. Defensive normalizer never crashes on missing/partial usage.     |
| `cache_control cannot be set for empty text blocks`     | Filters empty / whitespace-only text parts before serializing the turn to stream-json. Empty turns get a single-space placeholder so the cache breakpoint lands on something valid. |
| Stale session state after errors                        | Per `(cwd, modelId)` subprocess + session-id tracking. Process is killed and session id cleared on non-zero exit so the next turn spawns clean.          |
| Tool display                                            | Claude CLI executes `Read` / `Write` / `Edit` / `Bash` / `Glob` / `Grep` / `TodoWrite` internally; we stream them back as `providerExecuted: true` so OpenCode shows them without re-running. MCP tools are passed through for client-side execution. |

## Requirements

- [Claude CLI](https://docs.claude.com/en/docs/claude-code/overview) installed and authenticated (`claude auth login`).
- [OpenCode](https://opencode.ai) running under Bun (it imports `.ts` files directly — no build step needed).
- An active Claude Pro or Claude Max subscription (or Anthropic API key — the CLI accepts either).

## Install

Clone into any directory you'll keep long-term — the path will end up in
`opencode.json`.

```bash
git clone https://github.com/iamtheavoc1/opencode-claude-proxy.git ~/opencode-claude-proxy
```

Verify the `claude` binary is on your `PATH`:

```bash
claude --version
```

No build step, no `npm install` — the plugin has zero runtime dependencies
beyond Node's built-in `child_process`, `readline`, and `events`.

## Configure OpenCode

Add the provider to your `opencode.json` (or your project-local
`opencode.json` / `.opencode.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "claude-proxy": {
      "npm": "file:///absolute/path/to/opencode-claude-proxy/src/index.ts",
      "name": "Claude Proxy",
      "models": {
        "sonnet": {
          "name": "Claude Sonnet 4.6",
          "limit": { "context": 200000, "output": 16384 }
        },
        "opus": {
          "name": "Claude Opus 4.6",
          "limit": { "context": 200000, "output": 16384 }
        },
        "haiku": {
          "name": "Claude Haiku 4.5",
          "limit": { "context": 200000, "output": 8192 }
        }
      }
    }
  },
  "model": "claude-proxy/sonnet"
}
```

Replace `file:///absolute/path/to/opencode-claude-proxy/src/index.ts` with
the real absolute path (e.g. `file:///Users/you/opencode-claude-proxy/src/index.ts`).
OpenCode's provider loader explicitly supports `file://` URLs — see
`packages/opencode/src/provider/provider.ts` in the opencode source.

You only need to list the model tiers you actually plan to use. The CLI
accepts the aliases `sonnet`, `opus`, and `haiku` directly, so that's what
this plugin uses as model IDs.

Restart OpenCode. `claude-proxy/sonnet` (etc.) should now appear in the model
picker.

### Optional settings

You can pass options through the provider entry's `options` field:

```json
{
  "provider": {
    "claude-proxy": {
      "npm": "file:///...",
      "options": {
        "cliPath": "/custom/path/to/claude",
        "skipPermissions": true
      },
      "models": { "...": {} }
    }
  }
}
```

| Option            | Type      | Default                                          | Description                                                                                   |
| ----------------- | --------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `cliPath`         | `string`  | `$CLAUDE_CLI_PATH` or `"claude"` (on `$PATH`)    | Absolute path to the `claude` binary.                                                         |
| `cwd`             | `string`  | `process.cwd()`                                  | Working directory for the subprocess. Tool calls (`Read`, `Bash`, …) run relative to this.    |
| `skipPermissions` | `boolean` | `true`                                           | Pass `--dangerously-skip-permissions` so the CLI doesn't prompt. Set to `false` to re-enable. |

`$CLAUDE_CLI_PATH` (env var) overrides the default lookup if no `cliPath` is set in config.

## Debug logging

Set `DEBUG=claude-proxy` to get verbose stderr logs showing spawn arguments,
stream parts, and usage diagnostics:

```bash
DEBUG=claude-proxy opencode
```

## How it works

1. On each turn, OpenCode calls `doStream(options)` with a v3
   `LanguageModelV3CallOptions`.
2. The plugin extracts the system message (if any) and spawns
   `claude --model <tier> --output-format stream-json --input-format stream-json
   --verbose --system-prompt <...>` once per `(cwd, modelId)`. Subsequent turns
   reuse the same process so the CLI keeps its in-memory session state.
3. The current user turn is serialized to Anthropic stream-json format and
   written to the subprocess's stdin. Empty text blocks are filtered — see
   `src/message-builder.ts` for the full rules.
4. stdout lines are parsed as the CLI's stream-json output
   (`content_block_start/delta/stop`, `assistant`, `user`, `result`, …) and
   translated to AI SDK v3 `LanguageModelV3StreamPart`s
   (`text-start`/`text-delta`/`tool-call`/`tool-result`/…).
5. Usage is normalized to the v3 nested shape in `src/usage.ts`. Anthropic's
   flat `input_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens`
   become `inputTokens: { total, noCache, cacheRead, cacheWrite }` with
   `total = noCache + cacheRead + cacheWrite` — matching how OpenCode's session
   layer (`session/index.ts`) computes cost.

## Project layout

```
src/
├── index.ts                       # createClaudeProxy() factory (the `create*` export OpenCode looks for)
├── claude-proxy-language-model.ts # LanguageModelV3 implementation — doStream / doGenerate
├── usage.ts                       # toV3Usage() — defensive nested usage normalization
├── message-builder.ts             # prompt → Anthropic stream-json, with empty-block filter
├── tool-mapping.ts                # CLI tool names → OpenCode tool names + providerExecuted flags
├── session-manager.ts             # per-(cwd,modelId) subprocess + session-id tracking
└── logger.ts                      # DEBUG=claude-proxy logger
```

## Troubleshooting

**"claude-proxy: failed to spawn 'claude'"**
`claude` isn't on `$PATH`. Either fix your PATH or set `cliPath` in the
provider config to the absolute binary path.

**Stream hangs / no response**
Run with `DEBUG=claude-proxy` to see the raw CLI stream. If you see the CLI
exit immediately, try `claude --print "hi"` in a terminal to check it's
authenticated.

**"Session ID already in use"**
The previous turn's process died mid-stream. The plugin clears the stored
session id on non-zero exit codes and respawns fresh on the next turn — just
send another message.

**Usage shows zeros**
If the CLI doesn't emit a `result` message (e.g. aborted turns), usage falls
back to `undefined`. Nothing crashes; OpenCode just reports zero tokens for
that turn.

## Credits

Tool mapping and stream-parsing logic is adapted from the original
`opencode-claude-code-plugin`. This rewrite targets AI SDK v3, fixes the
`usage.inputTokens.total` and `cache_control` crashes, and is distributed as a
local file:// provider rather than an npm package.

## License

[MIT](./LICENSE)
