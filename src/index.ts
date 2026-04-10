// opencode-claude-proxy — local OpenCode provider
//
// Loaded by OpenCode via opencode.json `provider.<id>.npm = "file://..."`.
// OpenCode imports this module, looks for a function whose name begins with
// `create`, and calls it with `{ name, ...options }`. The returned object must
// expose `.languageModel(modelId)` returning an AI SDK v3 LanguageModelV3
// instance.
//
// Wiring example (see README.md for full setup):
//   {
//     "provider": {
//       "claude-proxy": {
//         "npm": "file:///absolute/path/to/opencode-claude-proxy/src/index.ts",
//         "name": "Claude Proxy",
//         "models": {
//           "sonnet": { "name": "Claude Sonnet 4.6" },
//           "opus":   { "name": "Claude Opus 4.6"   },
//           "haiku":  { "name": "Claude Haiku 4.5"  }
//         }
//       }
//     }
//   }

import { ClaudeProxyLanguageModel, type ClaudeProxyConfig } from "./claude-proxy-language-model.ts"

export interface ClaudeProxyProvider {
  (modelId: string): ClaudeProxyLanguageModel
  languageModel(modelId: string): ClaudeProxyLanguageModel
}

export function createClaudeProxy(settings: Partial<ClaudeProxyConfig> = {}): ClaudeProxyProvider {
  const config: ClaudeProxyConfig = {
    name: settings.name ?? "claude-proxy",
    cliPath: settings.cliPath ?? process.env.CLAUDE_CLI_PATH ?? "claude",
    cwd: settings.cwd,
    skipPermissions: settings.skipPermissions ?? true,
  }

  const createModel = (modelId: string): ClaudeProxyLanguageModel =>
    new ClaudeProxyLanguageModel(modelId, config)

  const provider = ((modelId: string) => createModel(modelId)) as ClaudeProxyProvider
  provider.languageModel = createModel
  return provider
}

export { ClaudeProxyLanguageModel }
export type { ClaudeProxyConfig }

export default createClaudeProxy
