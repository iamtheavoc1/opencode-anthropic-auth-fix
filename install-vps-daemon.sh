#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${1:-}"
OCAUTH_HOST_OVERRIDE="${2:-}"

if [ -z "$SSH_HOST" ]; then
  printf 'Usage: %s <ssh-host> [ocauth-host]\n' "$0" >&2
  exit 2
fi

PLUGIN_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"
AUTH_PATH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
CONFIG_PATH="$PLUGIN_DIR/.vps-config"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
PORT="${OCAUTH_PORT:-8787}"

step() { printf '\n==> %s\n' "$1"; }
ok() { printf '    ✓ %s\n' "$1"; }
fail() { printf '    ✗ %s\n' "$1" >&2; exit 1; }
note() { printf '      %s\n' "$1"; }

for tool in ssh scp python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done

[ -f "$AUTH_PATH" ] || fail "missing $AUTH_PATH"

step "Checking local Anthropic OAuth state"
AUTH_EXPORT="$(python3 - <<'PY'
import json, os, sys
p=os.path.expanduser(os.environ.get('OPENCODE_AUTH_PATH', '~/.local/share/opencode/auth.json'))
a=json.load(open(p)).get('anthropic', {})
if a.get('type') != 'oauth' or not a.get('access') or not a.get('refresh'):
    raise SystemExit(1)
print(a['access'])
print(a['refresh'])
print(a.get('expires', 0))
PY
)" || fail "local auth.json does not contain a usable anthropic oauth access+refresh pair"
ok "local auth.json contains a refreshable anthropic oauth entry"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/refresh.mjs" <<'EOF_REFRESH'
#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { renameSync, chmodSync, openSync, closeSync, unlinkSync } from 'node:fs';

const env = (k, required = true) => {
    const v = process.env[k];
    if (required && !v) {
        console.error(`FAIL: missing env ${k}`);
        process.exit(2);
    }
    return v;
};

const CLIENT_ID = env('OCAUTH_CLIENT_ID');
const TOKEN_URL = env('OCAUTH_TOKEN_URL');
const AGE_KEY = env('OCAUTH_AGE_KEY');
const AGE_PUBKEY = env('OCAUTH_AGE_PUBKEY');
const TOKEN_FILE = env('OCAUTH_TOKEN_FILE');
const THRESHOLD_MS = parseInt(env('OCAUTH_REFRESH_THRESHOLD_MS', false) || '3600000', 10);
const LOCK_FILE = env('OCAUTH_LOCK_FILE', false) || '/opt/ocauth/.lock';

const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);
const fail = (msg, code = 1) => { console.error(`[${new Date().toISOString()}] ${msg}`); process.exit(code); };

let lockFd = -1;
function acquireLock() {
    try {
        lockFd = openSync(LOCK_FILE, 'wx');
        return true;
    } catch (e) {
        if (e.code === 'EEXIST') {
            try {
                const { statSync } = require('node:fs');
                const age = Date.now() - statSync(LOCK_FILE).mtimeMs;
                if (age > 300000) {
                    log(`breaking stale lock (${Math.round(age / 1000)}s old)`);
                    unlinkSync(LOCK_FILE);
                    return acquireLock();
                }
            } catch {}
            log('another refresh in progress, skipping');
            return false;
        }
        throw e;
    }
}
function releaseLock() {
    if (lockFd >= 0) { try { closeSync(lockFd); } catch {} }
    try { unlinkSync(LOCK_FILE); } catch {}
}
process.on('exit', releaseLock);
process.on('SIGTERM', () => { releaseLock(); process.exit(0); });
process.on('SIGINT', () => { releaseLock(); process.exit(0); });

function decryptToken() {
    const r = spawnSync('age', ['-d', '-i', AGE_KEY, TOKEN_FILE], { encoding: 'utf8' });
    if (r.status !== 0) fail(`decrypt failed: ${r.stderr}`);
    try {
        return JSON.parse(r.stdout);
    } catch (e) {
        fail(`decrypt produced non-JSON: ${e.message}`);
    }
}

function encryptToken(tokenObj) {
    const tmp = TOKEN_FILE + '.tmp';
    const r = spawnSync('age', ['-r', AGE_PUBKEY, '-o', tmp], {
        input: JSON.stringify(tokenObj),
        encoding: 'utf8',
    });
    if (r.status !== 0) {
        try { unlinkSync(tmp); } catch {}
        fail(`encrypt failed: ${r.stderr}`);
    }
    renameSync(tmp, TOKEN_FILE);
    chmodSync(TOKEN_FILE, 0o600);
}

async function doRefresh(refreshToken) {
    const res = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/plain, */*',
            'User-Agent': 'axios/1.13.6',
        },
        body: JSON.stringify({
            grant_type: 'refresh_token',
            refresh_token: refreshToken,
            client_id: CLIENT_ID,
        }),
    });
    if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status}: ${text.slice(0, 300)}`);
    }
    const json = await res.json();
    if (!json.access_token || !json.refresh_token || typeof json.expires_in !== 'number') {
        throw new Error(`malformed response: ${JSON.stringify(json).slice(0, 200)}`);
    }
    return json;
}

async function main() {
    if (!acquireLock()) return;

    const token = decryptToken();
    if (token.type !== 'oauth') fail(`invalid token type: ${token.type}`);
    if (!token.refresh) fail('no refresh field in token');
    if (typeof token.expires !== 'number') fail(`invalid expires: ${token.expires}`);

    const msLeft = token.expires - Date.now();
    const hLeft = (msLeft / 3600000).toFixed(2);
    if (msLeft > THRESHOLD_MS) {
        log(`SKIP: ${hLeft}h remaining (threshold ${(THRESHOLD_MS / 3600000).toFixed(1)}h)`);
        return;
    }

    log(`REFRESH: ${hLeft}h remaining — calling OAuth endpoint`);
    let json;
    try {
        json = await doRefresh(token.refresh);
    } catch (e) {
        fail(`refresh failed: ${e.message}`);
    }

    encryptToken({
        type: 'oauth',
        access: json.access_token,
        refresh: json.refresh_token,
        expires: Date.now() + json.expires_in * 1000,
    });
    log(`OK: new expiry in ${(json.expires_in / 3600).toFixed(2)}h`);
}

main().catch((e) => fail(`unhandled: ${e.stack || e.message}`));
EOF_REFRESH

cat > "$TMPDIR/server.mjs" <<'EOF_SERVER'
#!/usr/bin/env node
import { createServer } from 'node:http';
import { spawnSync } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';

const env = (k, required = true) => {
    const v = process.env[k];
    if (required && !v) {
        console.error(`FAIL: missing env ${k}`);
        process.exit(2);
    }
    return v;
};

const BIND_ADDR = env('OCAUTH_BIND_ADDR');
const BIND_PORT = parseInt(env('OCAUTH_BIND_PORT'), 10);
const BEARER = env('OCAUTH_BEARER');
const AGE_KEY = env('OCAUTH_AGE_KEY');
const TOKEN_FILE = env('OCAUTH_TOKEN_FILE');

if (BIND_ADDR === '0.0.0.0' || BIND_ADDR === '' || BIND_ADDR.startsWith('0.')) {
    console.error(`FAIL: refusing to bind to ${BIND_ADDR} (must be explicit tailnet IP)`);
    process.exit(2);
}

const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);
const EXPECTED = Buffer.from(`Bearer ${BEARER}`, 'utf8');
function checkAuth(header) {
    if (typeof header !== 'string') return false;
    const got = Buffer.from(header, 'utf8');
    if (got.length !== EXPECTED.length) return false;
    try { return timingSafeEqual(got, EXPECTED); } catch { return false; }
}

function decryptToken() {
    const r = spawnSync('age', ['-d', '-i', AGE_KEY, TOKEN_FILE], { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`decrypt failed: ${r.stderr}`);
    return r.stdout;
}

const server = createServer((req, res) => {
    const respond = (status, bodyObj) => {
        const body = JSON.stringify(bodyObj);
        res.writeHead(status, {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body),
            'Cache-Control': 'no-store',
        });
        res.end(body);
        log(`${req.method || '-'} ${req.url || '-'} ${status} ${req.socket.remoteAddress || '-'}`);
    };

    if (req.method === 'GET' && req.url === '/health') return respond(200, { ok: true });
    if (req.method === 'GET' && req.url === '/token') {
        if (!checkAuth(req.headers.authorization)) return respond(401, { error: 'unauthorized' });
        try {
            const plaintext = decryptToken();
            res.writeHead(200, {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(plaintext),
                'Cache-Control': 'no-store',
            });
            res.end(plaintext);
            log(`${req.method || '-'} ${req.url || '-'} 200 ${req.socket.remoteAddress || '-'}`);
        } catch (e) {
            log(`DECRYPT ERROR: ${e.message}`);
            respond(503, { error: 'token_unavailable' });
        }
        return;
    }
    respond(404, { error: 'not_found' });
});

server.on('error', (e) => {
    console.error(`SERVER ERROR: ${e.message}`);
    process.exit(1);
});
server.listen(BIND_PORT, BIND_ADDR, () => log(`listening on ${BIND_ADDR}:${BIND_PORT}`));

const shutdown = (sig) => {
    log(`received ${sig}, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
EOF_SERVER

cat > "$TMPDIR/ocauth-refresh.service" <<'EOF_REFRESH_UNIT'
[Unit]
Description=OpenCode Anthropic OAuth Refresh (oneshot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=ocauth
Group=ocauth
EnvironmentFile=/opt/ocauth/.env
ExecStart=/usr/bin/node /opt/ocauth/refresh.mjs
ProtectSystem=strict
ReadWritePaths=/opt/ocauth
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
EOF_REFRESH_UNIT

cat > "$TMPDIR/ocauth-refresh.timer" <<'EOF_REFRESH_TIMER'
[Unit]
Description=OpenCode Anthropic OAuth Refresh Timer (30min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true
AccuracySec=1min
Unit=ocauth-refresh.service

[Install]
WantedBy=timers.target
EOF_REFRESH_TIMER

cat > "$TMPDIR/ocauth-server.service" <<'EOF_SERVER_UNIT'
[Unit]
Description=OpenCode Anthropic OAuth Token Server
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=simple
User=ocauth
Group=ocauth
EnvironmentFile=/opt/ocauth/.env
ExecStart=/usr/bin/node /opt/ocauth/server.mjs
Restart=always
RestartSec=5s
ProtectSystem=strict
ReadOnlyPaths=/opt/ocauth
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryMax=128M
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF_SERVER_UNIT

AUTH_EXPORT="$AUTH_EXPORT" python3 - <<'PY' > "$TMPDIR/token.json"
import sys
import os
lines = os.environ['AUTH_EXPORT'].splitlines()
access = lines[0]
refresh = lines[1]
expires = int(lines[2] or '0')
print('{')
print('  "type": "oauth",')
print(f'  "access": "{access}",')
print(f'  "refresh": "{refresh}",')
print(f'  "expires": {expires}')
print('}')
PY

BEARER="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

step "Probing SSH access"
ssh -o BatchMode=yes "$SSH_HOST" 'uname -s >/dev/null'
ok "SSH connection works"

step "Uploading provisioning payload"
scp "$TMPDIR/refresh.mjs" "$TMPDIR/server.mjs" "$TMPDIR/ocauth-refresh.service" "$TMPDIR/ocauth-refresh.timer" "$TMPDIR/ocauth-server.service" "$TMPDIR/token.json" "$SSH_HOST:/tmp/"
ok "payload uploaded"

step "Provisioning remote VPS"
REMOTE_ENV=$(cat <<EOF
CLIENT_ID='$CLIENT_ID'
TOKEN_URL='$TOKEN_URL'
BEARER='$BEARER'
PORT='$PORT'
EOF
)
ssh "$SSH_HOST" "$REMOTE_ENV bash -s" <<'EOF_REMOTE'
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required on the remote host" >&2
  exit 1
fi

sudo apt-get update -y
sudo apt-get install -y curl ca-certificates jq age nodejs

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sudo sh
fi

sudo systemctl enable --now tailscaled

if ! sudo tailscale status >/dev/null 2>&1; then
  echo "tailscale is installed but not connected; run 'sudo tailscale up' on the VPS, then re-run this script" >&2
  exit 1
fi

if ! id -u ocauth >/dev/null 2>&1; then
  sudo useradd --system --create-home --home-dir /opt/ocauth --shell /usr/sbin/nologin ocauth
fi

sudo install -d -m 700 -o ocauth -g ocauth /opt/ocauth
sudo install -d -m 755 /var/log/ocauth

if [ ! -f /opt/ocauth/key.txt ]; then
  sudo -u ocauth age-keygen -o /opt/ocauth/key.txt >/tmp/ocauth-agegen.out
fi

AGE_PUBKEY="$(sudo grep '^# public key:' /opt/ocauth/key.txt | awk '{print $4}')"
TS_IP="$(tailscale ip -4 | head -n 1)"
TS_FQDN="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self", {}).get("DNSName", "").rstrip("."))')"

[ -n "$TS_IP" ] || { echo 'could not determine tailscale IPv4' >&2; exit 1; }

sudo install -m 755 -o ocauth -g ocauth /tmp/refresh.mjs /opt/ocauth/refresh.mjs
sudo install -m 755 -o ocauth -g ocauth /tmp/server.mjs /opt/ocauth/server.mjs
sudo cp /tmp/ocauth-refresh.service /etc/systemd/system/ocauth-refresh.service
sudo cp /tmp/ocauth-refresh.timer /etc/systemd/system/ocauth-refresh.timer
sudo cp /tmp/ocauth-server.service /etc/systemd/system/ocauth-server.service

sudo install -m 600 -o ocauth -g ocauth /dev/null /opt/ocauth/.env
sudo bash -c "cat > /opt/ocauth/.env" <<EOF_ENV
OCAUTH_CLIENT_ID=${CLIENT_ID}
OCAUTH_TOKEN_URL=${TOKEN_URL}
OCAUTH_BIND_ADDR=${TS_IP}
OCAUTH_BIND_PORT=${PORT}
OCAUTH_BEARER=${BEARER}
OCAUTH_AGE_KEY=/opt/ocauth/key.txt
OCAUTH_AGE_PUBKEY=${AGE_PUBKEY}
OCAUTH_TOKEN_FILE=/opt/ocauth/token.age
OCAUTH_REFRESH_THRESHOLD_MS=3600000
OCAUTH_LOCK_FILE=/opt/ocauth/.lock
EOF_ENV
sudo chown ocauth:ocauth /opt/ocauth/.env
sudo chmod 600 /opt/ocauth/.env

sudo -u ocauth age -r "$AGE_PUBKEY" -o /opt/ocauth/token.age /tmp/token.json
sudo chown ocauth:ocauth /opt/ocauth/token.age
sudo chmod 600 /opt/ocauth/token.age
rm -f /tmp/token.json /tmp/refresh.mjs /tmp/server.mjs /tmp/ocauth-refresh.service /tmp/ocauth-refresh.timer /tmp/ocauth-server.service /tmp/ocauth-agegen.out

sudo systemctl daemon-reload
sudo systemctl enable --now ocauth-refresh.timer
sudo systemctl restart ocauth-server.service
sudo systemctl start ocauth-refresh.service
EOF_REMOTE
ssh "$SSH_HOST" 'sudo systemctl is-active ocauth-server.service >/dev/null && sudo systemctl is-active ocauth-refresh.timer >/dev/null'
TS_IP="$(ssh "$SSH_HOST" 'sh -lc ''. /opt/ocauth/.env; printf "%s" "$OCAUTH_BIND_ADDR"''')"
REMOTE_FQDN="$(ssh "$SSH_HOST" "tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"Self\",{}).get(\"DNSName\",\"\").rstrip(\".\"))'")"
OCAUTH_HOST="${OCAUTH_HOST_OVERRIDE:-${REMOTE_FQDN:-$TS_IP}}"

[ -n "$TS_IP" ] || fail "failed to determine remote tailscale IP"
[ -n "$OCAUTH_HOST" ] || fail "failed to determine OCAUTH host"
ok "remote services are active"
note "tailscale ip: $TS_IP"
note "host: $OCAUTH_HOST"

step "Writing local VPS config"
mkdir -p "$PLUGIN_DIR"
cat > "$CONFIG_PATH" <<EOF
OCAUTH_HOST=$OCAUTH_HOST
OCAUTH_TS_IP=$TS_IP
OCAUTH_PORT=$PORT
OCAUTH_BEARER=$BEARER
OCAUTH_SSH_HOST=$SSH_HOST
EOF
chmod 600 "$CONFIG_PATH"
ok "wrote $CONFIG_PATH"
note "OCAUTH_SSH_HOST=$SSH_HOST enables SSH fallback when Tailscale is unavailable"

step "Validating token server"
python3 - <<PY
import json, urllib.request
host = ${OCAUTH_HOST@Q}
port = ${PORT@Q}
bearer = ${BEARER@Q}
req = urllib.request.Request(f"http://{host}:{port}/health")
with urllib.request.urlopen(req, timeout=5) as r:
    health = json.loads(r.read().decode())
assert health.get('ok') is True
req = urllib.request.Request(f"http://{host}:{port}/token", headers={'Authorization': f'Bearer {bearer}'})
with urllib.request.urlopen(req, timeout=5) as r:
    token = json.loads(r.read().decode())
assert token.get('type') == 'oauth' and token.get('access') and token.get('refresh')
print('health_ok token_ok')
PY
ok "health check and token fetch passed"

cat <<EOF

Next:
  1. Re-run the main installer in VPS mode:
       OCAUTH_VPS_HOST=$OCAUTH_HOST OCAUTH_TS_IP=$TS_IP OCAUTH_BEARER=$BEARER bash ./fix-opencode.sh
  2. Reload your shell so the claude() wrapper picks up the VPS pull helper.
  3. Test:
       claude --print "say exactly: VPS_OK"

Recovery:
  - Local VPS config: $CONFIG_PATH
  - Remote env: ssh $SSH_HOST 'sudo cat /opt/ocauth/.env'
  - Remote logs: ssh $SSH_HOST 'sudo journalctl -u ocauth-server.service -u ocauth-refresh.service --since today'

EOF
