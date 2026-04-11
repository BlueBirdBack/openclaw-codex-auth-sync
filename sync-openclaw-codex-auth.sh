#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECKER_SCRIPT="$SCRIPT_DIR/check-openclaw-codex-auth.sh"
AUTH_PATH="/home/node/.openclaw/agents/main/agent/auth-profiles.json"
IDS=()
SOURCE_ID=""
SOURCE_PROFILE=""
DRY_RUN=0
NO_RESTART=0
NO_VERIFY=0
ALLOW_EXPIRED_SOURCE=0
FORCE=0
RESTART_DELAY=8
PROBE_TIMEOUT_MS=5000
WORKDIR="$(mktemp -d /tmp/sync-openclaw-codex-auth.XXXXXX)"
IDS_JOINED=""
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

cleanup() {
  if [[ "${KEEP_WORKDIR}" == "1" ]]; then
    echo "Keeping workdir: $WORKDIR"
    return
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: sync-openclaw-codex-auth.sh [options]

Repair/sync Codex OAuth across OpenClaw Docker gateways.

What v4 does:
- reads source auth from auth-profiles.json (not ~/.codex/auth.json)
- auto-detects the freshest usable openai-codex source profile
- backs up every target auth-profiles.json before patching
- patches BOTH openai-codex:default and the source named profile
- restarts containers staggered
- verifies stored metadata and attempts a best-effort live probe

Options:
  --ids "1 2 3 4 5 6"       Space-separated target ids to patch (required)
  --source-id N             Source container id (default: first id in --ids)
  --source-profile ID       Explicit source profile id (example: openai-codex:realpromptguru@gmail.com)
  --allow-expired-source    Allow selecting/propagating an expired source profile (not recommended)
  --force                   Bypass source live-probe gate and final healthy check
  --dry-run                 Show chosen source and planned target updates; do not write or restart
  --no-restart              Patch files but skip container restarts
  --no-verify               Skip post-patch verification/probe
  --restart-delay SEC       Delay between restarts (default: 8)
  --probe-timeout-ms N      Per-probe timeout for OpenClaw probe (default: 5000)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ids)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ids" >&2; exit 2; }
      read -r -a IDS <<< "$1"
      ;;
    --source-id)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --source-id" >&2; exit 2; }
      SOURCE_ID="$1"
      ;;
    --source-profile)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --source-profile" >&2; exit 2; }
      SOURCE_PROFILE="$1"
      ;;
    --allow-expired-source)
      ALLOW_EXPIRED_SOURCE=1
      ;;
    --force)
      FORCE=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    --no-verify)
      NO_VERIFY=1
      ;;
    --restart-delay)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --restart-delay" >&2; exit 2; }
      RESTART_DELAY="$1"
      ;;
    --probe-timeout-ms)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --probe-timeout-ms" >&2; exit 2; }
      PROBE_TIMEOUT_MS="$1"
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

if [[ ${#IDS[@]} -eq 0 ]]; then
  echo 'You must pass --ids, for example: --ids "1 2 3 4 5 6"' >&2
  exit 2
fi

if [[ -z "$SOURCE_ID" ]]; then
  SOURCE_ID="${IDS[0]}"
fi

mkdir -p "$WORKDIR/backups" "$WORKDIR/patched"
SRC_CONTAINER="openclaw-openclaw-gateway-${SOURCE_ID}-1"
SRC_FILE="$WORKDIR/source-auth.json"
IDS_JOINED="${IDS[*]}"
export IDS_JOINED ALLOW_EXPIRED_SOURCE FORCE PROBE_TIMEOUT_MS

require_container() {
  local c="$1"
  docker inspect "$c" >/dev/null 2>&1 || { echo "Container not found: $c" >&2; exit 2; }
}

require_auth_file() {
  local c="$1"
  docker exec "$c" test -f "$AUTH_PATH" || { echo "Auth file missing in $c: $AUTH_PATH" >&2; exit 2; }
}

echo "=== sync-openclaw-codex-auth ==="
echo "workdir: $WORKDIR"
echo "source container: $SRC_CONTAINER"
echo "targets: ${IDS[*]}"

require_container "$SRC_CONTAINER"
require_auth_file "$SRC_CONTAINER"
for id in "${IDS[@]}"; do
  c="openclaw-openclaw-gateway-${id}-1"
  require_container "$c"
  require_auth_file "$c"
done

docker cp "$SRC_CONTAINER:$AUTH_PATH" "$SRC_FILE"
chmod 600 "$SRC_FILE"

SELECTED_JSON=$(python3 - "$SRC_FILE" "$SOURCE_PROFILE" <<'PY'
import json, os, sys, time
src_path = sys.argv[1]
explicit = sys.argv[2].strip()
allow_expired = os.environ.get('ALLOW_EXPIRED_SOURCE') == '1' or os.environ.get('FORCE') == '1'
doc = json.load(open(src_path))
profiles = doc.get('profiles', {}) or {}
now = int(time.time() * 1000)

candidates = []
for key, value in profiles.items():
    if not isinstance(value, dict):
        continue
    if not key.startswith('openai-codex:'):
        continue
    refresh = value.get('refresh')
    expires = int(value.get('expires') or 0)
    candidates.append({
        'profileId': key,
        'expires': expires,
        'valid': expires > now,
        'hasRefresh': bool(refresh),
        'email': value.get('email'),
        'accountId': value.get('accountId'),
        'profile': value,
    })

selected = None
if explicit:
    for item in candidates:
        if item['profileId'] == explicit:
            selected = item
            break
    if selected is None:
        raise SystemExit(f'Explicit source profile not found: {explicit}')
    if (not selected['valid']) and (not allow_expired):
        raise SystemExit(f'Explicit source profile is expired: {explicit}. Re-run with --allow-expired-source or --force to override.')
else:
    non_default = [c for c in candidates if c['profileId'] != 'openai-codex:default' and c['hasRefresh']]
    valid_non_default = [c for c in non_default if c['valid']]
    valid_default = [c for c in candidates if c['profileId'] == 'openai-codex:default' and c['hasRefresh'] and c['valid']]
    expired_non_default = [c for c in non_default if not c['valid']]
    expired_default = [c for c in candidates if c['profileId'] == 'openai-codex:default' and c['hasRefresh'] and not c['valid']]
    if valid_non_default:
        selected = max(valid_non_default, key=lambda x: x['expires'])
    elif valid_default:
        selected = valid_default[0]
    elif allow_expired and expired_non_default:
        selected = max(expired_non_default, key=lambda x: x['expires'])
    elif allow_expired and expired_default:
        selected = max(expired_default, key=lambda x: x['expires'])
    else:
        raise SystemExit('No valid openai-codex source profile found in source auth-profiles.json. Re-run with --allow-expired-source or --force to override.')

print(json.dumps({
    'selectedProfileId': selected['profileId'],
    'expires': selected['expires'],
    'valid': selected['valid'],
    'hasRefresh': selected['hasRefresh'],
    'email': selected['email'],
    'accountId': selected['accountId'],
}, separators=(',', ':')))
PY
)

export SELECTED_JSON
SELECTED_SUMMARY=$(python3 - <<'PY'
import json, os
s = json.loads(os.environ['SELECTED_JSON'])
print(f"source profile: {s['selectedProfileId']} | valid={s['valid']} | email={s.get('email')} | refresh_present={'yes' if s.get('hasRefresh') else 'no'}")
PY
)
echo "$SELECTED_SUMMARY"

export SRC_CONTAINER
export SRC_PROFILE_ID=$(python3 - <<'PY'
import json, os
print(json.loads(os.environ['SELECTED_JSON'])['selectedProfileId'])
PY
)

echo
echo "=== Source probe gate ==="
SOURCE_PROBE_JSON=$(python3 - <<'PY'
import json, os, subprocess
container = os.environ['SRC_CONTAINER']
profile_id = os.environ['SRC_PROFILE_ID']
probe_timeout_ms = int(os.environ['PROBE_TIMEOUT_MS'])
cmd = [
    'docker', 'exec', container,
    'openclaw', 'models', 'status',
    '--json', '--probe',
    '--probe-provider', 'openai-codex',
    '--probe-profile', profile_id,
    '--probe-timeout', str(probe_timeout_ms),
]
try:
    cp = subprocess.run(cmd, text=True, capture_output=True, timeout=max(90, int(probe_timeout_ms / 1000) * 10 + 40), check=False)
except subprocess.TimeoutExpired as e:
    stdout = e.stdout.decode(errors='replace') if isinstance(e.stdout, (bytes, bytearray)) else (e.stdout or '')
    stderr = e.stderr.decode(errors='replace') if isinstance(e.stderr, (bytes, bytearray)) else (e.stderr or '')
    cp = subprocess.CompletedProcess(cmd, 124, stdout, stderr + '\nTIMEOUT')
text = (cp.stdout or '').strip()
lines = text.splitlines()
start = None
for i, line in enumerate(lines):
    if line.lstrip().startswith('{'):
        start = i
        break
payload = None
if start is not None:
    candidate = '\n'.join(lines[start:]).strip()
    last = candidate.rfind('}')
    if last != -1:
        payload = candidate[: last + 1]
status = 'unknown'
error = None
latency = None
if payload:
    try:
        data = json.loads(payload)
        results = (((data.get('auth') or {}).get('probes') or {}).get('results') or [])
        match = None
        for item in results:
            if item.get('profileId') == profile_id:
                match = item
                break
        if match is None and results:
            match = results[0]
        if match:
            status = match.get('status', 'unknown')
            error = match.get('error')
            latency = match.get('latencyMs')
        else:
            error = 'no probe result'
    except Exception as e:
        error = f'json parse failed: {e}'
else:
    error = 'probe json not found'
print(json.dumps({'status': status, 'error': error, 'latencyMs': latency}, separators=(',', ':')))
PY
)
export SOURCE_PROBE_JSON
python3 - <<'PY'
import json, os
p = json.loads(os.environ['SOURCE_PROBE_JSON'])
msg = f"source probe: status={p.get('status')}"
if p.get('latencyMs') is not None:
    msg += f" latencyMs={p.get('latencyMs')}"
if p.get('error'):
    msg += f" error={p.get('error')}"
print(msg)
PY
SOURCE_PROBE_STATUS=$(python3 - <<'PY'
import json, os
print(json.loads(os.environ['SOURCE_PROBE_JSON'])['status'])
PY
)
if [[ "$SOURCE_PROBE_STATUS" != "ok" && "$FORCE" -ne 1 ]]; then
  echo "Refusing to propagate: source live probe is not ok. Re-run with --force to override." >&2
  exit 2
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "=== Dry run target plan ==="
fi

for id in "${IDS[@]}"; do
  c="openclaw-openclaw-gateway-${id}-1"
  backup="$WORKDIR/backups/auth-profiles-oc${id}.json"
  patched="$WORKDIR/patched/auth-profiles-oc${id}.json"

  echo "-- oc${id}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    docker exec "$c" python3 - "$SRC_FILE" "$AUTH_PATH" <<'PY'
import json, sys, time
src_doc = json.load(open(sys.argv[1]))
auth_path = sys.argv[2]
dst_doc = json.load(open(auth_path))
selected = json.loads(os.environ['SELECTED_JSON'])
profile_id = selected['selectedProfileId']
src_profiles = src_doc.get('profiles', {}) or {}
src = src_profiles[profile_id]

dst_profiles = dst_doc.setdefault('profiles', {})
payload = {
    'type': 'oauth',
    'provider': 'openai-codex',
    'access': src['access'],
    'refresh': src['refresh'],
    'expires': src['expires'],
    'accountId': src.get('accountId'),
}
if src.get('email'):
    payload['email'] = src.get('email')

current = dst_profiles.get('openai-codex:default', {}) or {}
exp = int(payload.get('expires') or 0)
now = int(time.time() * 1000)
left = int((exp - now) / 3600000) if exp > now else -1
would_change = (
    current.get('access') != payload['access']
    or current.get('refresh') != payload['refresh']
    or int(current.get('expires') or 0) != exp
    or current.get('accountId') != payload.get('accountId')
    or current.get('email') != payload.get('email')
    or dst_profiles.get(profile_id) != payload
)
print(f"   would patch default: email={payload.get('email')} hours_left={left} refresh={'yes' if payload.get('refresh') else 'no'} change={'yes' if would_change else 'no'}")
PY
  else
    docker cp "$c:$AUTH_PATH" "$backup"
    chmod 600 "$backup"

    python3 - "$SRC_FILE" "$backup" "$patched" <<'PY'
import json, os, sys
src_doc = json.load(open(sys.argv[1]))
dst_doc = json.load(open(sys.argv[2]))
out_path = sys.argv[3]
selected = json.loads(os.environ['SELECTED_JSON'])
profile_id = selected['selectedProfileId']
src_profiles = src_doc.get('profiles', {}) or {}
src = src_profiles[profile_id]

dst_profiles = dst_doc.setdefault('profiles', {})
payload = {
    'type': 'oauth',
    'provider': 'openai-codex',
    'access': src['access'],
    'refresh': src['refresh'],
    'expires': src['expires'],
    'accountId': src.get('accountId'),
}
if src.get('email'):
    payload['email'] = src.get('email')

# Patch runtime-default profile.
dst_profiles['openai-codex:default'] = dict(payload)
# Also copy the named source profile so live probing can use it explicitly.
dst_profiles[profile_id] = dict(payload)

dst_doc.setdefault('lastGood', {})['openai-codex'] = 'openai-codex:default'
usage = dst_doc.setdefault('usageStats', {})
usage.setdefault('openai-codex:default', {})['errorCount'] = 0
usage.setdefault(profile_id, {})['errorCount'] = 0

with open(out_path, 'w') as f:
    json.dump(dst_doc, f, indent=2)
os.chmod(out_path, 0o600)

print(json.dumps({
    'targetDefaultExpires': payload['expires'],
    'targetProfileId': profile_id,
    'email': payload.get('email'),
    'accountId': payload.get('accountId'),
}, separators=(',', ':')))
PY

    docker cp "$patched" "$c:$AUTH_PATH"
    docker exec -u root "$c" chown node:node "$AUTH_PATH"
    docker exec -u root "$c" chmod 600 "$AUTH_PATH"
    echo "   patched + backed up"
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run complete. No files were written and no containers were restarted."
  exit 0
fi

if [[ "$NO_RESTART" -eq 0 ]]; then
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

if [[ "$NO_VERIFY" -eq 1 ]]; then
  echo
  echo "Skipping verification (--no-verify)."
  echo "Backups: $WORKDIR/backups"
  echo "Set KEEP_WORKDIR=1 to preserve temporary files after exit."
  exit 0
fi

echo
echo "=== Verify metadata ==="
for id in "${IDS[@]}"; do
  c="openclaw-openclaw-gateway-${id}-1"
  echo -n "oc${id}: "
  docker exec "$c" python3 - <<'PY'
import json, time
p = json.load(open('/home/node/.openclaw/agents/main/agent/auth-profiles.json')).get('profiles', {}).get('openai-codex:default', {})
exp = int(p.get('expires') or 0)
now = int(time.time() * 1000)
left = int((exp - now) / 3600000) if exp > now else -1
status = 'valid' if exp > now else 'expired'
print(f"{status} hours_left={left} refresh={'yes' if p.get('refresh') else 'no'} email={p.get('email')}")
PY
done

echo
echo "=== Final checker verdict ==="
if [[ ! -x "$CHECKER_SCRIPT" ]]; then
  echo "Checker script missing or not executable: $CHECKER_SCRIPT" >&2
  exit 2
fi
set +e
"$CHECKER_SCRIPT" --ids "$IDS_JOINED" --probe-timeout-ms "$PROBE_TIMEOUT_MS"
CHECK_RC=$?
set -e
if [[ "$CHECK_RC" -ne 0 && "$FORCE" -ne 1 ]]; then
  echo "Final checker did not report all targets healthy. Re-run with --force to override this gate." >&2
  exit 2
fi
if [[ "$CHECK_RC" -ne 0 && "$FORCE" -eq 1 ]]; then
  echo "Final checker reported non-healthy targets, but continuing because --force was set." >&2
fi

echo
echo "Backups: $WORKDIR/backups"
echo "Patched files: $WORKDIR/patched"
echo "Set KEEP_WORKDIR=1 to preserve temporary files after exit."
