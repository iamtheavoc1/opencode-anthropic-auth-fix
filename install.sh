#!/usr/bin/env bash
# opencode-claude-proxy installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/install.sh | bash
#
# Environment overrides (optional):
#   OPENCODE_CLAUDE_PROXY_DIR   target clone dir      (default: ~/.local/share/opencode-claude-proxy)
#   OPENCODE_CONFIG             opencode.json path    (default: ~/.config/opencode/opencode.json)
#   OPENCODE_CLAUDE_PROXY_REF   branch / tag / sha    (default: main)
#   OPENCODE_CLAUDE_PROXY_SET_DEFAULT_MODEL=1         also set "model": "claude-proxy/sonnet" when none exists

set -euo pipefail

REPO_URL="${OPENCODE_CLAUDE_PROXY_REPO:-https://github.com/iamtheavoc1/opencode-claude-proxy.git}"
REF="${OPENCODE_CLAUDE_PROXY_REF:-main}"
INSTALL_DIR="${OPENCODE_CLAUDE_PROXY_DIR:-$HOME/.local/share/opencode-claude-proxy}"
CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
SET_DEFAULT_MODEL="${OPENCODE_CLAUDE_PROXY_SET_DEFAULT_MODEL:-0}"

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_red()    { printf '\033[31m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$1"; }

step()  { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()    { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn()  { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }
fail()  { printf '    %s %s\n' "$(c_red '✗')"    "$1"; exit 1; }
note()  { printf '      %s\n'    "$(c_dim "$1")"; }

# ─── Requirements ────────────────────────────────────────────────────────────
step "Checking requirements"

# Resolve a tool by looking it up on PATH, then falling back to common install
# locations (Bun installs to ~/.bun/bin by default, Claude CLI to ~/.local/bin,
# Homebrew to /opt/homebrew/bin or /usr/local/bin, etc.). Sets a global named
# "<TOOL>_BIN" on success.
resolve_tool() {
  local tool="$1"
  shift
  local found
  found=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$found" ] && [ -x "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

GIT_BIN=$(resolve_tool git /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git) \
  || fail "git not found — install from https://git-scm.com/downloads"
ok "git — $("$GIT_BIN" --version | awk '{print $3}')"

CLAUDE_BIN=$(resolve_tool claude \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/local/claude" \
    /opt/homebrew/bin/claude \
    /usr/local/bin/claude) \
  || fail "claude CLI not found — install from https://docs.claude.com/en/docs/claude-code/overview then run: claude login"
CLAUDE_VER=$("$CLAUDE_BIN" --version 2>/dev/null || echo "unknown")
ok "claude CLI — $CLAUDE_VER"
note "binary: $CLAUDE_BIN"

BUN_BIN=$(resolve_tool bun \
    "$HOME/.bun/bin/bun" \
    /opt/homebrew/bin/bun \
    /usr/local/bin/bun) \
  || fail "bun not found — OpenCode runs under bun. Install: curl -fsSL https://bun.sh/install | bash"
ok "bun — $("$BUN_BIN" --version)"
note "binary: $BUN_BIN"

# Make the resolved paths available to any later `command -v` lookups and to
# subshells the installer spawns.
export PATH="$(dirname "$BUN_BIN"):$(dirname "$CLAUDE_BIN"):$(dirname "$GIT_BIN"):$PATH"

# Non-fatal: warn if CLI doesn't even respond to --help
if ! "$CLAUDE_BIN" --help >/dev/null 2>&1; then
  warn "claude CLI did not respond to --help — run 'claude login' if you hit auth errors later"
fi

# ─── Clone / update ──────────────────────────────────────────────────────────
step "Installing plugin to $INSTALL_DIR"

if [ -d "$INSTALL_DIR/.git" ]; then
  ok "existing install detected — updating"
  "$GIT_BIN" -C "$INSTALL_DIR" fetch --quiet --depth 1 origin "$REF"
  "$GIT_BIN" -C "$INSTALL_DIR" reset --quiet --hard FETCH_HEAD
elif [ -e "$INSTALL_DIR" ]; then
  fail "$INSTALL_DIR exists but isn't a git checkout — move or delete it and re-run"
else
  mkdir -p "$(dirname "$INSTALL_DIR")"
  "$GIT_BIN" clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$INSTALL_DIR"
  ok "cloned $REPO_URL"
fi

ENTRY_PATH="$INSTALL_DIR/src/index.ts"
if [ ! -f "$ENTRY_PATH" ]; then
  fail "plugin entry not found at $ENTRY_PATH — aborting"
fi
ENTRY_URL="file://$ENTRY_PATH"
ok "entry: $ENTRY_URL"

# ─── Sanity-load the plugin ──────────────────────────────────────────────────
step "Verifying plugin loads"

"$BUN_BIN" -e "
import create from '$ENTRY_PATH';
const p = create();
const m = p.languageModel('sonnet');
if (m.specificationVersion !== 'v3') { console.error('expected v3, got', m.specificationVersion); process.exit(1); }
console.log('    ' + '\u2713' + ' specificationVersion=' + m.specificationVersion + ' provider=' + m.provider);
" || fail "plugin failed to load — report an issue at https://github.com/iamtheavoc1/opencode-claude-proxy/issues"

# ─── Merge provider config into opencode.json ────────────────────────────────
step "Updating $CONFIG_PATH"

mkdir -p "$(dirname "$CONFIG_PATH")"

# Back up any existing config before touching it.
if [ -f "$CONFIG_PATH" ]; then
  BACKUP="$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$BACKUP"
  ok "backup: $BACKUP"
fi

CONFIG_PATH="$CONFIG_PATH" ENTRY_URL="$ENTRY_URL" SET_DEFAULT_MODEL="$SET_DEFAULT_MODEL" "$BUN_BIN" -e '
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const path = process.env.CONFIG_PATH;
const entry = process.env.ENTRY_URL;
const setDefault = process.env.SET_DEFAULT_MODEL === "1";

let cfg = {};
if (existsSync(path)) {
  const raw = readFileSync(path, "utf-8").trim();
  if (raw) {
    try { cfg = JSON.parse(raw); }
    catch (e) {
      console.error("    ✗ existing " + path + " is not valid JSON: " + e.message);
      console.error("      fix the file or delete it and re-run");
      process.exit(1);
    }
  }
}

if (!cfg.$schema) cfg.$schema = "https://opencode.ai/config.json";

cfg.provider = cfg.provider ?? {};
cfg.provider["claude-proxy"] = {
  npm: entry,
  name: "Claude Proxy",
  models: {
    sonnet: { name: "Claude Sonnet 4.6", limit: { context: 200000, output: 16384 } },
    opus:   { name: "Claude Opus 4.6",   limit: { context: 200000, output: 16384 } },
    haiku:  { name: "Claude Haiku 4.5",  limit: { context: 200000, output: 8192 } },
  },
};

let setModelNote = null;
if (setDefault && !cfg.model) {
  cfg.model = "claude-proxy/sonnet";
  setModelNote = "set default model to claude-proxy/sonnet";
}

writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
console.log("    \u2713 provider \"claude-proxy\" registered (sonnet / opus / haiku)");
if (setModelNote) console.log("    \u2713 " + setModelNote);
' || fail "failed to update $CONFIG_PATH"

# ─── Also apply opencode-claude-bridge subscription-billing patches ──────────
# If the user has opencode-claude-bridge installed (for Anthropic subscription
# billing via OAuth), the published version sends a dynamic `cch` hash and the
# SDK-mode system prompt, which routes every request into Anthropic's
# "extra usage" pool. We patch it so it matches what the real `claude` CLI
# sends (cch=00000, cli prompt, cc_entrypoint=cli). Safe no-op if bridge is
# not installed.
if [ -d "$HOME/.cache/opencode/node_modules/opencode-claude-bridge" ] || \
   compgen -G "$HOME/.cache/opencode/packages/opencode-claude-bridge*/node_modules/opencode-claude-bridge" >/dev/null 2>&1; then
  step "Applying opencode-claude-bridge subscription-billing patches"
  if curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/patch-bridge.sh | bash; then
    ok "bridge patched"
  else
    warn "bridge patch step failed (non-fatal) — run it manually:"
    note "curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/patch-bridge.sh | bash"
  fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────
step "Done"
cat <<EOF

  Plugin:  $INSTALL_DIR
  Config:  $CONFIG_PATH

  Next:
    1. (Re)start OpenCode
    2. Pick one of: claude-proxy/sonnet | claude-proxy/opus | claude-proxy/haiku

  To update:        re-run this installer
  To uninstall:     rm -rf "$INSTALL_DIR"  (and remove the "claude-proxy" entry from your opencode.json)
  Debug logs:       DEBUG=claude-proxy opencode

EOF
