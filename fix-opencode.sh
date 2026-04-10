#!/usr/bin/env bash
# fix-opencode.sh — make OpenCode bill Anthropic calls against your Claude
# Pro/Max subscription instead of hitting "You're out of extra usage".
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/fix-opencode.sh | bash
#
# What it does, in order:
#   1. Verifies requirements (claude CLI, opencode, npm/git)
#   2. Downloads @ex-machina/opencode-anthropic-auth from npm (the only plugin
#      that actually handles Anthropic's OAuth request-shape validation correctly)
#   3. Installs it to ~/.local/share/opencode-anthropic-auth
#   4. Updates ~/.config/opencode/opencode.json:
#      - removes any previously installed opencode-claude-bridge entry
#      - removes any previously installed claude-proxy provider entry
#      - adds the ex-machina plugin via file:// reference
#      - sets default model to anthropic/claude-sonnet-4-6 if none is set
#   5. Backs up your opencode.json before modifying
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

# ─── Update opencode.json ────────────────────────────────────────────────────
step "Updating $CONFIG_PATH"

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ -f "$CONFIG_PATH" ]; then
  BAK="$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$BAK"
  ok "backup: $BAK"
fi

PY_BIN=$(resolve_tool python3 /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3) \
  || fail "python3 not found — required to safely update opencode.json"

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
