// Map Claude CLI tool names and argument shapes to OpenCode's expected names.
//
// Claude CLI executes many tools internally (Read, Write, Edit, Bash, etc.).
// Those must be reported as `providerExecuted: true` so OpenCode doesn't try to
// execute them again on the client. MCP tools and tools OpenCode handles itself
// are passed through for client-side execution.

function mapToolInput(name: string, input: any): any {
  if (!input) return input
  switch (name) {
    case "Write":
      return {
        filePath: input.file_path ?? input.filePath,
        content: input.content,
      }
    case "Edit":
      return {
        filePath: input.file_path ?? input.filePath,
        oldString: input.old_string ?? input.oldString,
        newString: input.new_string ?? input.newString,
        replaceAll: input.replace_all ?? input.replaceAll,
      }
    case "Read":
      return {
        filePath: input.file_path ?? input.filePath,
        offset: input.offset,
        limit: input.limit,
      }
    case "Bash":
      return {
        command: input.command,
        description:
          input.description ||
          `Execute: ${String(input.command || "").slice(0, 50)}${String(input.command || "").length > 50 ? "..." : ""}`,
        timeout: input.timeout,
      }
    case "Glob":
      return { pattern: input.pattern, path: input.path }
    case "Grep":
      return { pattern: input.pattern, path: input.path, include: input.include }
    case "TodoWrite":
      if (Array.isArray(input.todos)) {
        const mappedTodos = input.todos.map((todo: any, index: number) => ({
          content: todo.content,
          status: todo.status || "pending",
          priority: todo.priority || "medium",
          id: todo.id || `todo_${Date.now()}_${index}`,
        }))
        return { todos: mappedTodos }
      }
      return input
    default:
      return input
  }
}

const OPENCODE_HANDLED_TOOLS = new Set([
  "Edit",
  "Write",
  "Bash",
  "TodoWrite",
  "Read",
  "Glob",
  "Grep",
])

const CLAUDE_INTERNAL_TOOLS = new Set([
  "ToolSearch",
  "Agent",
  "AskFollowupQuestion",
  "AskUserQuestion",
])

export interface MappedTool {
  name: string
  input?: any
  executed: boolean
  skip?: boolean
}

export function mapTool(name: string, input?: any): MappedTool {
  if (CLAUDE_INTERNAL_TOOLS.has(name)) {
    return { name, input, executed: true, skip: true }
  }

  if (name === "EnterPlanMode") return { name: "plan_enter", input: {}, executed: false }
  if (name === "ExitPlanMode") return { name: "plan_exit", input: {}, executed: false }

  if (name === "WebSearch" || name === "web_search") {
    const mapped = input?.query ? { query: input.query } : input
    return { name: "websearch_web_search_exa", input: mapped, executed: false }
  }

  if (name.startsWith("mcp__")) {
    const parts = name.slice(5).split("__")
    if (parts.length >= 2) {
      const serverName = parts[0]
      const toolName = parts.slice(1).join("_")
      return { name: `${serverName}_${toolName}`, input, executed: false }
    }
  }

  if (OPENCODE_HANDLED_TOOLS.has(name)) {
    return {
      name: name.toLowerCase(),
      input: mapToolInput(name, input),
      executed: true,
    }
  }

  return { name, input, executed: true }
}
