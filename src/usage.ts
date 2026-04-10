// Defensive usage normalization.
//
// Claude CLI reports usage in Anthropic's flat format:
//   { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens }
// OpenCode expects AI SDK v3 LanguageModelV3Usage (nested):
//   {
//     inputTokens:  { total, noCache, cacheRead, cacheWrite },
//     outputTokens: { total, text,   reasoning },
//     raw?: { ... }
//   }
// Any of these fields can be undefined without crashing consumers — but
// `inputTokens` and `outputTokens` MUST be objects, not numbers, or v3
// consumers reading `.inputTokens.total` will throw
// "undefined is not an object".

export interface V3Usage {
  inputTokens: {
    total: number | undefined
    noCache: number | undefined
    cacheRead: number | undefined
    cacheWrite: number | undefined
  }
  outputTokens: {
    total: number | undefined
    text: number | undefined
    reasoning: number | undefined
  }
  raw?: Record<string, unknown>
}

function num(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined
  return value
}

export function toV3Usage(raw: any): V3Usage {
  // Anthropic reports input_tokens as the NON-CACHED count; cache read/write
  // counts are tracked separately. OpenCode expects inputTokens.total to be
  // the all-inclusive total (it subtracts cache counts itself when computing
  // cost — see opencode session/index.ts getUsage). So total = nonCached +
  // cacheRead + cacheWrite.
  //
  // We also accept already-nested v3 shapes and old v2 flat shapes as
  // fallbacks so rewiring a misbehaving upstream never crashes us.

  const nestedInput =
    raw?.inputTokens && typeof raw.inputTokens === "object" ? raw.inputTokens : undefined
  const nestedOutput =
    raw?.outputTokens && typeof raw.outputTokens === "object" ? raw.outputTokens : undefined

  const cacheRead = num(
    raw?.cache_read_input_tokens ??
      raw?.cachedInputTokens ??
      nestedInput?.cacheRead,
  )
  const cacheWrite = num(
    raw?.cache_creation_input_tokens ??
      raw?.cacheCreationInputTokens ??
      nestedInput?.cacheWrite,
  )

  // The "raw" Anthropic input_tokens field = non-cached portion.
  const nonCached = num(
    raw?.input_tokens ??
      nestedInput?.noCache ??
      (typeof raw?.inputTokens === "number" ? raw.inputTokens : undefined) ??
      raw?.promptTokens,
  )

  // If a nested shape already supplied an absolute total, trust it; otherwise
  // compose total = nonCached + cacheRead + cacheWrite so OpenCode's billing
  // math matches the Anthropic provider's behavior.
  const preComputedTotal = num(nestedInput?.total)
  const inputTotal =
    preComputedTotal !== undefined
      ? preComputedTotal
      : nonCached !== undefined || cacheRead !== undefined || cacheWrite !== undefined
      ? (nonCached ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
      : undefined

  const outputTotal = num(
    raw?.output_tokens ??
      nestedOutput?.total ??
      (typeof raw?.outputTokens === "number" ? raw.outputTokens : undefined) ??
      raw?.completionTokens,
  )
  const reasoningTokens = num(raw?.reasoning_tokens ?? nestedOutput?.reasoning)

  return {
    inputTokens: {
      total: inputTotal,
      noCache: nonCached,
      cacheRead,
      cacheWrite,
    },
    outputTokens: {
      total: outputTotal,
      text: outputTotal !== undefined ? outputTotal - (reasoningTokens ?? 0) : undefined,
      reasoning: reasoningTokens,
    },
    raw: raw && typeof raw === "object" ? (raw as Record<string, unknown>) : undefined,
  }
}

export const EMPTY_USAGE: V3Usage = {
  inputTokens: { total: undefined, noCache: undefined, cacheRead: undefined, cacheWrite: undefined },
  outputTokens: { total: undefined, text: undefined, reasoning: undefined },
}
