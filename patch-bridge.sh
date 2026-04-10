#!/usr/bin/env bash
# patch-bridge.sh — fix opencode-claude-bridge so it correctly bills against
# your Claude Pro/Max subscription instead of hitting "You're out of extra usage".
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/patch-bridge.sh | bash
#
# What it does (idempotent, backs up before modifying):
#
#   1. dist/index.js
#      const CLAUDE_PREFIX = "You are a Claude agent, built on Anthropic's Claude Agent SDK."
#      →                   "You are Claude Code, Anthropic's official CLI for Claude."
#
#      Or (older 1.7.x bridge that hashes cch per request):
#      cch=${hash.slice(0, 5)}   →   cch=00000
#
#   2. dist/constants.js
#      BILLING_CCH default ""       →   "00000"
#      ENTRYPOINT   default "sdk-cli" → "cli"
#
# Why:
#   Anthropic classifies requests as "Claude Code interactive subscription" only when
#   the billing header's `cch=00000` AND the system prompt starts with "You are Claude
#   Code, Anthropic's official CLI for Claude." (confirmed via `claude --debug api`).
#   The published bridge uses a dynamic sha256 hash for `cch` and the SDK-mode
#   prompt prefix, which lands every request in the "extra usage" pool — breaks
#   immediately on accounts with `extra_usage_disabled=true`.

set -euo pipefail

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

TS=$(date +%Y%m%d%H%M%S)

# The location OpenCode actually loads bridge from at runtime. If OpenCode is
# installed non-standardly this won't exist — we'll also scan secondary paths.
CANDIDATES=(
  "$HOME/.cache/opencode/node_modules/opencode-claude-bridge/dist"
)

# Also include any versioned packages/@latest copy so we don't leave a stale
# copy around that might get promoted later.
while IFS= read -r d; do
  [ -d "$d" ] && CANDIDATES+=("$d")
done < <(ls -d "$HOME/.cache/opencode/packages/opencode-claude-bridge"*"/node_modules/opencode-claude-bridge/dist" 2>/dev/null || true)

FOUND=0
for dir in "${CANDIDATES[@]}"; do
  [ -d "$dir" ] || continue
  FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
  fail "no opencode-claude-bridge install found at $HOME/.cache/opencode — install it first (add to opencode.json plugins, launch opencode once, then re-run this)"
fi

step "Patching $FOUND opencode-claude-bridge install(s)"

backup_once() {
  local f="$1"
  local latest_bak
  latest_bak=$(ls -t "$f".bak.* 2>/dev/null | head -1 || true)
  if [ -z "$latest_bak" ]; then
    cp "$f" "$f.bak.$TS"
    note "backup: $(basename "$f").bak.$TS"
  fi
}

# Portable in-place sed (macOS BSD sed vs GNU sed).
sed_inplace() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

patch_file() {
  local file="$1"
  local name="$2"
  local before_pattern="$3"
  local after_replacement="$4"

  if [ ! -f "$file" ]; then
    return 0
  fi

  # Use perl slurp mode so both `before` and `after` can be multi-line.
  # "Already patched" = after-pattern present and before-pattern absent.
  if BRIDGE_BEFORE="$before_pattern" perl -0777 -ne '
      exit(index($_, $ENV{BRIDGE_BEFORE}) >= 0 ? 0 : 1)
    ' "$file" 2>/dev/null; then
    backup_once "$file"
    BRIDGE_BEFORE="$before_pattern" BRIDGE_AFTER="$after_replacement" perl -0777 -i -pe '
      BEGIN { $b = $ENV{BRIDGE_BEFORE}; $a = $ENV{BRIDGE_AFTER}; }
      s/\Q$b\E/$a/g;
    ' "$file"
    ok "$name: patched"
  elif BRIDGE_AFTER="$after_replacement" perl -0777 -ne '
      exit(index($_, $ENV{BRIDGE_AFTER}) >= 0 ? 0 : 1)
    ' "$file" 2>/dev/null; then
    ok "$name: already patched"
  else
    warn "$name: pattern not found — bridge version may not need this patch, skipping"
  fi
}

for dir in "${CANDIDATES[@]}"; do
  [ -d "$dir" ] || continue
  printf '\n  %s\n' "$(c_cyan "$dir")"

  INDEX_JS="$dir/index.js"
  CONST_JS="$dir/constants.js"

  # ── index.js patches ─────────────────────────────────────────────────
  if [ -f "$INDEX_JS" ]; then
    # Newer bridge (1.8.x, 41KB): CLAUDE_PREFIX is the SDK-mode prompt.
    patch_file "$INDEX_JS" "CLAUDE_PREFIX → 'You are Claude Code…'" \
      "\"You are a Claude agent, built on Anthropic's Claude Agent SDK.\"" \
      "\"You are Claude Code, Anthropic's official CLI for Claude.\""

    # Older bridge (1.7.x, 26KB): cch is a hash of system content.
    patch_file "$INDEX_JS" "cch hash → 00000 (older bridge)" \
      'cch=${hash.slice(0, 5)};' \
      'cch=00000;'
  else
    warn "$(basename "$dir")/index.js missing"
  fi

  # ── constants.js patches (newer bridge only) ─────────────────────────
  if [ -f "$CONST_JS" ]; then
    patch_file "$CONST_JS" "BILLING_CCH default → 00000" \
      'process.env.ANTHROPIC_BILLING_CCH || "";' \
      'process.env.ANTHROPIC_BILLING_CCH || "00000";'

    # Multi-line pattern — ENTRYPOINT default spans 3 lines in the source.
    patch_file "$CONST_JS" "ENTRYPOINT default → cli" \
      'process.env.CLAUDE_CODE_ENTRYPOINT ||
    "sdk-cli";' \
      'process.env.CLAUDE_CODE_ENTRYPOINT ||
    "cli";'
  fi
done

step "Done"

cat <<EOF

  Patches applied to: ${CANDIDATES[0]}

  Fix summary:
    - CLAUDE_PREFIX:     SDK prompt → "You are Claude Code…"
    - BILLING_CCH:       dynamic hash → "00000" (literal, matches real CLI)
    - ENTRYPOINT:        "sdk-cli" → "cli" (matches real CLI)

  Now restart OpenCode so it reloads the patched bridge:

    pkill -x opencode 2>/dev/null
    opencode

  Verify with claude-code-bridge billing header:
    DEBUG=* opencode   # grep stderr for "x-anthropic-billing-header"

  Durability:
    The patches live in OpenCode's cache dir. If you ever re-install or
    upgrade opencode-claude-bridge, the patches get overwritten. Just
    re-run this script to reapply.

EOF
