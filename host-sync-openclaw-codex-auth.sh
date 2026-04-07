#!/usr/bin/env bash
set -euo pipefail

IDS=()
RESTART=1
RESTART_DELAY=8
CODEX_AUTH_PATH="${CODEX_AUTH_PATH:-$HOME/.codex/auth.json}"
AUTH_PATH="/home/node/.openclaw/agents/main/agent/auth-profiles.json"

usage() {
  cat <<'EOF'
Usage: host-sync-openclaw-codex-auth.sh [options]

Sync fresh OAuth tokens from the host Codex CLI auth file into OpenClaw agent auth caches.

Options:
  --ids "1 2 3 4 5 6"   Space-separated container ids to patch (required)
  --auth-path PATH      Host Codex auth.json path (default: ~/.codex/auth.json)
  --no-restart          Patch files but skip container restarts
  --restart-delay SEC   Delay between restarts (default: 8)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ids)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ids" >&2; exit 2; }
      read -r -a IDS <<< "$1"
      ;;
    --auth-path)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --auth-path" >&2; exit 2; }
      CODEX_AUTH_PATH="$1"
      ;;
    --no-restart)
      RESTART=0
      ;;
    --restart-delay)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --restart-delay" >&2; exit 2; }
      RESTART_DELAY="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 2; }
[[ ${#IDS[@]} -gt 0 ]] || { echo "You must pass --ids, for example: --ids \"1 2 3 4 5 6\"" >&2; exit 2; }
[[ -f "$CODEX_AUTH_PATH" ]] || { echo "Host auth file not found: $CODEX_AUTH_PATH" >&2; exit 2; }

WORKDIR="/tmp/host-sync-openclaw-codex-auth-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORKDIR/backups"

echo "=== host-sync-openclaw-codex-auth ==="
echo "host auth: $CODEX_AUTH_PATH"
echo "targets: ${IDS[*]}"

tmp_json="$WORKDIR/codex-auth.json"
cp "$CODEX_AUTH_PATH" "$tmp_json"
export TMP_CODEX_AUTH="$tmp_json"

for id in "${IDS[@]}"; do
  c="openclaw-openclaw-gateway-${id}-1"
  echo "-- oc${id}"
  docker inspect "$c" >/dev/null 2>&1 || { echo "Container not found: $c" >&2; exit 2; }
  docker exec "$c" test -f "$AUTH_PATH" || { echo "Auth file missing in $c: $AUTH_PATH" >&2; exit 2; }
  docker cp "$c:$AUTH_PATH" "$WORKDIR/backups/auth-profiles-oc${id}.json"

  docker exec "$c" python3 - <<'PY'
import base64, json, os
from pathlib import Path

host_auth = json.load(open(os.environ['TMP_CODEX_AUTH']))
tokens = host_auth['tokens']
access = tokens['access_token']
refresh = tokens['refresh_token']
account_id = tokens.get('account_id')

payload_b64 = access.split('.')[1]
payload_b64 += '=' * (-len(payload_b64) % 4)
payload = json.loads(base64.urlsafe_b64decode(payload_b64.encode()).decode())
expires_ms = int(payload['exp']) * 1000
profile = payload.get('https://api.openai.com/profile') or {}
email = profile.get('email') or payload.get('email')

path = Path('/home/node/.openclaw/agents/main/agent/auth-profiles.json')
data = json.load(path.open())
profiles = data.get('profiles', {})
changed = []
for key, prof in profiles.items():
    if isinstance(prof, dict) and prof.get('provider') == 'openai-codex' and prof.get('type') == 'oauth':
        prof['access'] = access
        prof['refresh'] = refresh
        prof['expires'] = expires_ms
        if account_id:
            prof['accountId'] = account_id
        if email and key != 'openai-codex:default':
            prof['email'] = email
        changed.append(key)

if 'openai-codex:default' not in profiles:
    profiles['openai-codex:default'] = {
        'type': 'oauth',
        'provider': 'openai-codex',
        'access': access,
        'refresh': refresh,
        'expires': expires_ms,
    }
    if account_id:
        profiles['openai-codex:default']['accountId'] = account_id
    changed.append('openai-codex:default')

if 'lastGood' in data and isinstance(data['lastGood'], dict):
    if email and f'openai-codex:{email}' in profiles:
        data['lastGood']['openai-codex'] = f'openai-codex:{email}'
    else:
        data['lastGood']['openai-codex'] = 'openai-codex:default'

with path.open('w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(json.dumps({'email': email, 'accountId': account_id, 'expires': expires_ms, 'changed': changed}))
PY

done

if [[ "$RESTART" -eq 1 ]]; then
  echo
  echo "=== Restart staggered ==="
  for id in "${IDS[@]}"; do
    c="openclaw-openclaw-gateway-${id}-1"
    echo "restart oc${id}"
    docker restart "$c" >/dev/null
    sleep "$RESTART_DELAY"
  done
else
  echo
  echo "Skipping restarts (--no-restart)."
fi

echo

echo "Backups: $WORKDIR/backups"
