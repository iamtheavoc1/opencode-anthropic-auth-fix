#!/usr/bin/env bash
# fix-opencode.sh — make OpenCode bill Anthropic calls against your Claude
# Pro/Max subscription instead of hitting "You're out of extra usage".
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/fix-opencode.sh | bash
#
# What it does, in order:
#   1. Verifies requirements (claude CLI, opencode, npm/git)
#   2. Downloads @ex-machina/opencode-anthropic-auth from npm (the only plugin
#      that actually handles Anthropic's OAuth request-shape validation correctly)
#   3. Installs it to ~/.local/share/opencode-anthropic-auth
#   4. Patches the installed plugin so expired OAuth sessions self-heal:
#      - refreshes within 60s of expiry instead of waiting until fully expired
#      - if OpenCode's refresh token has gone stale but Claude CLI is still
#        logged in, borrows a fresh Claude CLI bearer token locally and keeps going
#   5. Updates ~/.config/opencode/opencode.json:
#      - removes any previously installed opencode-claude-bridge entry
#      - removes any previously installed claude-proxy provider entry
#      - adds the ex-machina plugin via file:// reference
#      - sets default model to anthropic/claude-sonnet-4-6 if none is set
#   6. Backs up your opencode.json before modifying
#
# Why this is needed — the actual root cause:
#
#   Anthropic's /v1/messages API validates the `system[]` array for OAuth
#   requests. ONLY the Claude Code identity block is allowed in system[];
#   anything else (OpenCode's agent prompts, tool descriptions, Sisyphus
#   configuration, etc.) triggers a 400 that surfaces as
#   "You're out of extra usage". It's a misleading error — the pool isn't
#   the problem, it's the request shape.
#
#   The ex-machina plugin transparently relocates every non-identity
#   system block to the first user message, satisfying the validation.
#   opencode-claude-bridge does NOT do this, which is why it produces the
#   error on every turn that involves OMO, OpenCode's tool descriptions,
#   or any multi-block system prompt.
#
#   Verified end-to-end by running `opencode run` with Sisyphus
#   (OhMyOpenCode) agent — sonnet-4-6 returns HTTP 200 and the expected
#   response text.

set -euo pipefail

REPO_ENTRY_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"
CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
PLUGIN_REF="file://$REPO_ENTRY_DIR/dist/index.js"
NPM_PKG="@ex-machina/opencode-anthropic-auth"

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_red()    { printf '\033[31m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$1"; }

step() { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn() { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }
fail() { printf '    %s %s\n' "$(c_red '✗')"    "$1"; exit 1; }
note() { printf '      %s\n' "$(c_dim "$1")"; }

resolve_tool() {
  local tool="$1"; shift
  local found
  found=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$found" ] && [ -x "$found" ]; then printf '%s' "$found"; return 0; fi
  for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}

# ─── Requirements ────────────────────────────────────────────────────────────
step "Checking requirements"

GIT_BIN=$(resolve_tool git /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git) \
  || fail "git not found — install from https://git-scm.com/downloads"
ok "git — $("$GIT_BIN" --version | awk '{print $3}')"

CLAUDE_BIN=$(resolve_tool claude "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude) \
  || fail "claude CLI not found — https://docs.claude.com/en/docs/claude-code/overview, then run 'claude login'"
ok "claude CLI — $("$CLAUDE_BIN" --version 2>/dev/null || echo unknown)"
note "binary: $CLAUDE_BIN"

NPM_BIN=$(resolve_tool npm /opt/homebrew/bin/npm /usr/local/bin/npm) \
  || fail "npm not found — required to download the plugin from the npm registry"
ok "npm — $("$NPM_BIN" --version)"

OPENCODE_BIN=$(resolve_tool opencode "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode) \
  || warn "opencode binary not found on PATH — installer will still work, but you'll need to install OpenCode before it takes effect"
[ -n "${OPENCODE_BIN:-}" ] && ok "opencode — $("$OPENCODE_BIN" --version 2>/dev/null | head -1)"

PY_BIN=$(resolve_tool python3 /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3) \
  || fail "python3 not found — required to patch the plugin and safely update opencode.json"
ok "python3 — $("$PY_BIN" --version 2>/dev/null | awk '{print $2}')"

# ─── Download + install the plugin ───────────────────────────────────────────
step "Installing $NPM_PKG to $REPO_ENTRY_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
(
  cd "$TMPDIR"
  "$NPM_BIN" pack "$NPM_PKG" --silent 2>/dev/null || fail "failed to download $NPM_PKG from npm"
) || exit 1

TARBALL=$(ls "$TMPDIR"/*.tgz 2>/dev/null | head -1)
[ -n "$TARBALL" ] || fail "npm pack produced no tarball"

tar -xzf "$TARBALL" -C "$TMPDIR" || fail "failed to extract $TARBALL"

mkdir -p "$(dirname "$REPO_ENTRY_DIR")"
rm -rf "$REPO_ENTRY_DIR"
mv "$TMPDIR/package" "$REPO_ENTRY_DIR"

[ -f "$REPO_ENTRY_DIR/dist/index.js" ] || fail "extracted plugin is missing dist/index.js"
ok "installed to $REPO_ENTRY_DIR"
ok "entry: $PLUGIN_REF"

# ─── Patch plugin auth recovery ──────────────────────────────────────────────
step "Patching plugin auth recovery"

cat > "$REPO_ENTRY_DIR/dist/claude-cli-sync.js" <<'JS'
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
const SYNC_PROMPT = 'say exactly: AUTH_SYNC_OK';
const SYNC_MODEL = process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_MODEL || 'claude-sonnet-4-6';
const SYNC_TIMEOUT_MS = Number(process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_TIMEOUT_MS || 20000);
const SYNC_TTL_MS = Number(process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_TTL_MS || 1800000);
function resolveClaudeBin() {
    const candidates = [
        process.env.CLAUDE_BIN,
        join(homedir(), '.local/bin/claude'),
        join(homedir(), '.claude/local/claude'),
        '/opt/homebrew/bin/claude',
        '/usr/local/bin/claude',
        'claude',
    ].filter(Boolean);
    for (const candidate of candidates) {
        if (candidate === 'claude' || existsSync(candidate))
            return candidate;
    }
    return 'claude';
}
function captureClaudeCliBearer() {
    return new Promise((resolve, reject) => {
        let child = null;
        let settled = false;
        let timeout = null;
        let stderr = '';
        const finish = (handler, value) => {
            if (settled)
                return;
            settled = true;
            if (timeout)
                clearTimeout(timeout);
            server.close();
            if (child && child.exitCode === null) {
                child.kill('SIGTERM');
            }
            handler(value);
        };
        const server = createServer((req, res) => {
            if (req.method === 'HEAD') {
                res.writeHead(200);
                res.end();
                return;
            }
            if (req.method === 'POST' && req.url?.startsWith('/v1/messages')) {
                const authorization = req.headers.authorization;
                res.writeHead(204);
                res.end();
                if (typeof authorization === 'string' && authorization.startsWith('Bearer ')) {
                    finish(resolve, authorization.slice('Bearer '.length));
                    return;
                }
                finish(reject, new Error('Claude CLI token sync captured no bearer token'));
                return;
            }
            res.writeHead(404);
            res.end();
        });
        server.on('error', (error) => finish(reject, error));
        server.listen(0, '127.0.0.1', () => {
            const address = server.address();
            if (!address || typeof address === 'string') {
                finish(reject, new Error('Claude CLI token sync failed to bind loopback server'));
                return;
            }
            const env = {
                ...process.env,
                ANTHROPIC_BASE_URL: `http://127.0.0.1:${address.port}`,
            };
            child = spawn(resolveClaudeBin(), ['--print', SYNC_PROMPT, '--model', SYNC_MODEL], {
                cwd: homedir(),
                env,
                stdio: ['ignore', 'ignore', 'pipe'],
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
                if (stderr.length > 2000) {
                    stderr = stderr.slice(-2000);
                }
            });
            child.on('error', (error) => finish(reject, error));
            child.on('exit', (code) => {
                if (!settled) {
                    const suffix = stderr.trim() ? ` — ${stderr.trim()}` : '';
                    finish(reject, new Error(`Claude CLI exited before token sync completed (${code ?? 'unknown'})${suffix}`));
                }
            });
        });
        timeout = setTimeout(() => {
            finish(reject, new Error('Timed out syncing token from Claude CLI'));
        }, SYNC_TIMEOUT_MS);
    });
}
export async function syncClaudeCliAccessToken() {
    const access = await captureClaudeCliBearer();
    return {
        access,
        expires: Date.now() + Math.max(60000, SYNC_TTL_MS),
    };
}
JS

REPO_ENTRY_DIR="$REPO_ENTRY_DIR" "$PY_BIN" - <<'PY' || fail "failed to patch plugin auth recovery"
from pathlib import Path
import os, sys

index_path = Path(os.environ["REPO_ENTRY_DIR"]) / "dist" / "index.js"
src = index_path.read_text()

import_line = "import { createStrippedStream, isInsecure, mergeHeaders, rewriteRequestBody, rewriteUrl, setOAuthHeaders, } from './transform';\n"
if "syncClaudeCliAccessToken" not in src:
    if import_line not in src:
        print("    unsupported upstream index.js layout (import line not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(import_line, import_line + "import { syncClaudeCliAccessToken } from './claude-cli-sync';\n", 1)

marker = "                    let refreshPromise = null;\n"
helper = """                    let refreshPromise = null;\n                    let cliSyncPromise = null;\n                    const syncFromClaudeCli = async () => {\n                        if (!cliSyncPromise) {\n                            cliSyncPromise = (async () => {\n                                const synced = await syncClaudeCliAccessToken();\n                                const existing = await getAuth();\n                                const preservedRefresh = existing.type === 'oauth' ? existing.refresh : undefined;\n                                await client.auth.set({\n                                    path: {\n                                        id: 'anthropic',\n                                    },\n                                    body: {\n                                        type: 'oauth',\n                                        refresh: preservedRefresh,\n                                        access: synced.access,\n                                        expires: synced.expires,\n                                    },\n                                });\n                                return synced.access;\n                            })().finally(() => {\n                                cliSyncPromise = null;\n                            });\n                        }\n                        return await cliSyncPromise;\n                    };\n                    const refreshOrSync = async () => {\n                        const latest = await getAuth();\n                        if (latest.type !== 'oauth' || !latest.refresh) {\n                            return await syncFromClaudeCli();\n                        }\n                        if (!refreshPromise) {\n                            refreshPromise = (async () => {\n                                const maxRetries = 2;\n                                const baseDelayMs = 500;\n                                for (let attempt = 0; attempt <= maxRetries; attempt++) {\n                                    try {\n                                        if (attempt > 0) {\n                                            const delay = baseDelayMs * 2 ** (attempt - 1);\n                                            await new Promise((resolve) => setTimeout(resolve, delay));\n                                        }\n                                        const response = await fetch(TOKEN_URL, {\n                                            method: 'POST',\n                                            headers: {\n                                                'Content-Type': 'application/json',\n                                                Accept: 'application/json, text/plain, */*',\n                                                'User-Agent': 'axios/1.13.6',\n                                            },\n                                            body: JSON.stringify({\n                                                grant_type: 'refresh_token',\n                                                refresh_token: latest.refresh,\n                                                client_id: CLIENT_ID,\n                                            }),\n                                        });\n                                        if (!response.ok) {\n                                            if (response.status >= 500 && attempt < maxRetries) {\n                                                await response.body?.cancel();\n                                                continue;\n                                            }\n                                            const body = await response.text().catch(() => '');\n                                            const isInvalidGrant = response.status == 400 && body.includes('invalid_grant');\n                                            if (isInvalidGrant) {\n                                                return await syncFromClaudeCli();\n                                            }\n                                            throw new Error(`Token refresh failed: ${response.status} — ${body}`);\n                                        }\n                                        const json = (await response.json());\n                                        await client.auth.set({\n                                            path: {\n                                                id: 'anthropic',\n                                            },\n                                            body: {\n                                                type: 'oauth',\n                                                refresh: json.refresh_token,\n                                                access: json.access_token,\n                                                expires: Date.now() + json.expires_in * 1000,\n                                            },\n                                        });\n                                        return json.access_token;\n                                    }\n                                    catch (error) {\n                                        const isNetworkError = error instanceof Error &&\n                                            (error.message.includes('fetch failed') ||\n                                                ('code' in error &&\n                                                    (error.code === 'ECONNRESET' ||\n                                                        error.code === 'ECONNREFUSED' ||\n                                                        error.code === 'ETIMEDOUT' ||\n                                                        error.code === 'UND_ERR_CONNECT_TIMEOUT')));\n                                        if (attempt < maxRetries && isNetworkError) {\n                                            continue;\n                                        }\n                                        throw error;\n                                    }\n                                }\n                                throw new Error('Token refresh exhausted all retries');\n                            })().finally(() => {\n                                refreshPromise = null;\n                            });\n                        }\n                        return await refreshPromise;\n                    };\n"""
if "const syncFromClaudeCli = async () => {" not in src:
    if marker not in src:
        print("    unsupported upstream index.js layout (refresh marker not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(marker, helper, 1)

old_if = """                            if (!auth.access || !auth.expires || auth.expires < Date.now()) {\n                                if (!refreshPromise) {\n                                    refreshPromise = (async () => {\n                                        const maxRetries = 2;\n                                        const baseDelayMs = 500;\n                                        for (let attempt = 0; attempt <= maxRetries; attempt++) {\n                                            try {\n                                                if (attempt > 0) {\n                                                    const delay = baseDelayMs * 2 ** (attempt - 1);\n                                                    await new Promise((resolve) => setTimeout(resolve, delay));\n                                                }\n                                                const response = await fetch(TOKEN_URL, {\n                                                    method: 'POST',\n                                                    headers: {\n                                                        'Content-Type': 'application/json',\n                                                        Accept: 'application/json, text/plain, */*',\n                                                        'User-Agent': 'axios/1.13.6',\n                                                    },\n                                                    body: JSON.stringify({\n                                                        grant_type: 'refresh_token',\n                                                        refresh_token: auth.refresh,\n                                                        client_id: CLIENT_ID,\n                                                    }),\n                                                });\n                                                if (!response.ok) {\n                                                    if (response.status >= 500 && attempt < maxRetries) {\n                                                        await response.body?.cancel();\n                                                        continue;\n                                                    }\n                                                    const body = await response.text().catch(() => '');\n                                                    throw new Error(`Token refresh failed: ${response.status} — ${body}`);\n                                                }\n                                                const json = (await response.json());\n                                                // biome-ignore lint/suspicious/noExplicitAny: SDK types don't expose auth.set\n                                                await client.auth.set({\n                                                    path: {\n                                                        id: 'anthropic',\n                                                    },\n                                                    body: {\n                                                        type: 'oauth',\n                                                        refresh: json.refresh_token,\n                                                        access: json.access_token,\n                                                        expires: Date.now() + json.expires_in * 1000,\n                                                    },\n                                                });\n                                                return json.access_token;\n                                            }\n                                            catch (error) {\n                                                const isNetworkError = error instanceof Error &&\n                                                    (error.message.includes('fetch failed') ||\n                                                        ('code' in error &&\n                                                            (error.code === 'ECONNRESET' ||\n                                                                error.code === 'ECONNREFUSED' ||\n                                                                error.code === 'ETIMEDOUT' ||\n                                                                error.code === 'UND_ERR_CONNECT_TIMEOUT')));\n                                                if (attempt < maxRetries && isNetworkError) {\n                                                    continue;\n                                                }\n                                                throw error;\n                                            }\n                                        }\n                                        // Unreachable — each iteration either returns or throws.\n                                        // Kept as a TypeScript exhaustiveness guard.\n                                        throw new Error('Token refresh exhausted all retries');\n                                    })().finally(() => {\n                                        refreshPromise = null;\n                                    });\n                                }\n                                auth.access = await refreshPromise;\n                            }\n"""

new_if = """                            if (!auth.access || !auth.expires || auth.expires < Date.now() + 60000) {\n                                auth.access = await refreshOrSync();\n                            }\n"""

if "auth.expires < Date.now() + 60000" not in src or "return await syncFromClaudeCli();" not in src:
    if old_if not in src:
        print("    unsupported upstream index.js layout (refresh block not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_if, new_if, 1)

old_fetch = """                            const response = await fetch(rewritten.input, {\n                                ...init,\n                                body,\n                                headers: requestHeaders,\n                                ...(isInsecure() && { tls: { rejectUnauthorized: false } }),\n                            });\n                            return createStrippedStream(response);\n"""

new_fetch = """                            const sendRequest = async (headers) => await fetch(rewritten.input, {\n                                ...init,\n                                body,\n                                headers,\n                                ...(isInsecure() && { tls: { rejectUnauthorized: false } }),\n                            });\n                            const isRetryableAuthFailure = async (response) => {\n                                if (response.status === 401 || response.status === 403) {\n                                    return true;\n                                }\n                                if (response.status !== 400) {\n                                    return false;\n                                }\n                                const bodyText = await response.clone().text().catch(() => '');\n                                const lowered = bodyText.toLowerCase();\n                                return lowered.includes('invalid authentication credentials') ||\n                                    (lowered.includes('authentication') && lowered.includes('invalid'));\n                            };\n                            let response = await sendRequest(requestHeaders);\n                            if (await isRetryableAuthFailure(response)) {\n                                auth.access = await refreshOrSync();\n                                const retryHeaders = new Headers(requestHeaders);\n                                setOAuthHeaders(retryHeaders, auth.access);\n                                response = await sendRequest(retryHeaders);\n                            }\n                            return createStrippedStream(response);\n"""

if "const sendRequest = async (headers) => await fetch(rewritten.input, {" not in src:
    if old_fetch not in src:
        print("    unsupported upstream index.js layout (request fetch block not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_fetch, new_fetch, 1)

index_path.write_text(src)
PY

ok "refreshes early, force-refreshes bad live tokens, and falls back to Claude CLI when refresh is unavailable"

# ─── Update opencode.json ────────────────────────────────────────────────────
step "Updating $CONFIG_PATH"

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ -f "$CONFIG_PATH" ]; then
  BAK="$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$BAK"
  ok "backup: $BAK"
fi

CONFIG_PATH="$CONFIG_PATH" PLUGIN_REF="$PLUGIN_REF" "$PY_BIN" - <<'PY' || fail "failed to update $CONFIG_PATH"
import json, os, sys
path = os.environ["CONFIG_PATH"]
plug = os.environ["PLUGIN_REF"]

cfg = {}
if os.path.isfile(path):
    with open(path, "r") as f:
        raw = f.read().strip()
    if raw:
        try:
            cfg = json.loads(raw)
        except Exception as e:
            print(f"    existing {path} is not valid JSON: {e}", file=sys.stderr)
            sys.exit(1)

if "$schema" not in cfg:
    cfg["$schema"] = "https://opencode.ai/config.json"

plugins = cfg.get("plugin")
if not isinstance(plugins, list):
    plugins = []

# Remove any conflicting plugins on the anthropic auth slot.
keep = []
for p in plugins:
    if p == "opencode-claude-bridge":
        continue
    if p == "opencode-claude-code-plugin":
        continue
    if isinstance(p, str) and "/opencode-anthropic-auth/" in p:
        continue
    keep.append(p)
if plug not in keep:
    keep.append(plug)
cfg["plugin"] = keep

providers = cfg.get("provider")
if not isinstance(providers, dict):
    providers = {}
providers.pop("claude-proxy", None)
providers.pop("claude-code", None)
cfg["provider"] = providers

current = cfg.get("model") or ""
if (not current) or current.startswith("claude-code/") or current.startswith("claude-proxy/"):
    cfg["model"] = "anthropic/claude-sonnet-4-6"

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("    plugin: " + json.dumps(cfg["plugin"]))
print("    model:  " + cfg["model"])
PY

ok "plugin registered, legacy entries removed"

# ─── Done ────────────────────────────────────────────────────────────────────
step "Done"

cat <<EOF

  Plugin:  $REPO_ENTRY_DIR
  Config:  $CONFIG_PATH

  Now restart OpenCode so it picks up the new plugin:

    pkill -x opencode 2>/dev/null
    opencode

  Test with any Anthropic model:

    opencode run "say hi" --model anthropic/claude-sonnet-4-6

  Re-run this installer any time to update the plugin to the latest version
  on npm or to re-apply the config after something clobbers it.

EOF
