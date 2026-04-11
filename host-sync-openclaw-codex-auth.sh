#!/usr/bin/env bash
set -euo pipefail
umask 077

IDS=()
RESTART=1
RESTART_DELAY=8
DRY_RUN=0
JSON_MODE=0
CODEX_AUTH_PATH="${CODEX_AUTH_PATH:-$HOME/.codex/auth.json}"
AUTH_PATH="/home/node/.openclaw/agents/main/agent/auth-profiles.json"

usage() {
  cat <<'EOF'
Usage: host-sync-openclaw-codex-auth.sh [options]

Sync fresh OAuth tokens from the host Codex CLI auth file into OpenClaw agent auth caches.

Options:
  --ids "1 2 3 4 5 6"   Space-separated container ids to patch (required)
  --auth-path PATH      Host Codex auth.json path (default: ~/.codex/auth.json)
  --dry-run             Inspect targets and report changes without writing or restarting
  --json                Emit machine-readable JSON summary
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
    --dry-run)
      DRY_RUN=1
      ;;
    --json)
      JSON_MODE=1
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
docker ps >/dev/null 2>&1 || {
  echo "docker is installed but not accessible from this shell (daemon unreachable or /var/run/docker.sock permission denied)." >&2
  echo "If you were just added to the docker group, start a fresh login shell or run: newgrp docker" >&2
  exit 2
}
[[ ${#IDS[@]} -gt 0 ]] || { echo 'You must pass --ids, for example: --ids "1 2 3 4 5 6"' >&2; exit 2; }
[[ -f "$CODEX_AUTH_PATH" ]] || { echo "Host auth file not found: $CODEX_AUTH_PATH" >&2; exit 2; }

WORKDIR="$(mktemp -d /tmp/host-sync-openclaw-codex-auth.XXXXXX)"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
cleanup() {
  if [[ "${KEEP_WORKDIR}" == "1" ]]; then
    echo "Keeping workdir: $WORKDIR"
    return
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
mkdir -p "$WORKDIR/backups"
cp "$CODEX_AUTH_PATH" "$WORKDIR/codex-auth.json"
chmod 600 "$WORKDIR/codex-auth.json"

export TMP_CODEX_AUTH="$WORKDIR/codex-auth.json"
export AUTH_PATH IDS_STR="${IDS[*]}" DRY_RUN JSON_MODE BACKUP_DIR="$WORKDIR/backups"

python3 - <<'PY'
import base64, json, os, subprocess, sys, time
from pathlib import Path

ids = [x for x in os.environ.get('IDS_STR', '').split() if x]
auth_path = os.environ['AUTH_PATH']
dry_run = os.environ.get('DRY_RUN') == '1'
json_mode = os.environ.get('JSON_MODE') == '1'
backup_dir = Path(os.environ['BACKUP_DIR'])
host_auth = json.load(open(os.environ['TMP_CODEX_AUTH']))
tokens = host_auth['tokens']
access = tokens['access_token']
refresh = tokens['refresh_token']
account_id = tokens.get('account_id')

payload_b64 = access.split('.')[1]
payload_b64 += '=' * (-len(payload_b64) % 4)
payload = json.loads(base64.urlsafe_b64decode(payload_b64.encode()).decode())
host_expires = int(payload['exp']) * 1000
profile = payload.get('https://api.openai.com/profile') or {}
host_email = profile.get('email') or payload.get('email')
now_ms = int(time.time() * 1000)

results = []
for cid in ids:
    container = f'openclaw-openclaw-gateway-{cid}-1'
    row = {'id': cid, 'container': container}
    inspect = subprocess.run(['docker', 'inspect', container], text=True, capture_output=True)
    if inspect.returncode != 0:
        row['status'] = 'missing_container'
        results.append(row)
        continue
    test = subprocess.run(['docker', 'exec', container, 'test', '-f', auth_path], text=True, capture_output=True)
    if test.returncode != 0:
        row['status'] = 'missing_auth_file'
        results.append(row)
        continue
    read = subprocess.run([
        'docker', 'exec', container, 'python3', '-c',
        f"import json; print(json.dumps(json.load(open('{auth_path}'))))"
    ], text=True, capture_output=True)
    if read.returncode != 0:
        row['status'] = 'read_failed'
        row['error'] = (read.stderr or read.stdout).strip()
        results.append(row)
        continue
    data = json.loads(read.stdout)
    profiles = data.get('profiles', {}) or {}
    default = profiles.get('openai-codex:default') or {}
    current_expires = int(default.get('expires') or 0)
    current_refresh = default.get('refresh') or ''
    current_email = default.get('email')
    if not current_email:
        for key, prof in profiles.items():
            if key.startswith('openai-codex:') and isinstance(prof, dict) and prof.get('email'):
                current_email = prof.get('email')
                break
    changed_profiles = [
        key for key, prof in profiles.items()
        if isinstance(prof, dict) and prof.get('provider') == 'openai-codex' and prof.get('type') == 'oauth'
    ]
    if 'openai-codex:default' not in profiles:
        changed_profiles.append('openai-codex:default')
    would_change = current_expires != host_expires or current_refresh != refresh or (host_email and current_email != host_email)
    row.update({
        'status': 'ok',
        'default_profile_exists': 'openai-codex:default' in profiles,
        'current_expires': current_expires,
        'host_expires': host_expires,
        'current_hours_left': int((current_expires - now_ms) / 3600000) if current_expires > now_ms else -1,
        'host_hours_left': int((host_expires - now_ms) / 3600000),
        'current_refresh_present': bool(current_refresh),
        'host_refresh_present': bool(refresh),
        'current_email': current_email,
        'host_email': host_email,
        'changed_profiles': changed_profiles,
        'would_change': would_change,
        'needs_restart': would_change,
    })
    if not dry_run:
        backup_path = backup_dir / f'auth-profiles-oc{cid}.json'
        cp = subprocess.run(['docker', 'cp', f'{container}:{auth_path}', str(backup_path)], text=True, capture_output=True)
        if cp.returncode != 0:
            row['status'] = 'backup_failed'
            row['error'] = (cp.stderr or cp.stdout).strip()
            results.append(row)
            continue
        backup_path.chmod(0o600)
        patch_code = f'''import base64, json\nfrom pathlib import Path\nhost_auth=json.loads({json.dumps(json.dumps(host_auth))})\ntokens=host_auth["tokens"]\naccess=tokens["access_token"]\nrefresh=tokens["refresh_token"]\naccount_id=tokens.get("account_id")\npayload_b64=access.split(".")[1]\npayload_b64 += "=" * (-len(payload_b64) % 4)\npayload=json.loads(base64.urlsafe_b64decode(payload_b64.encode()).decode())\nexpires_ms=int(payload["exp"])*1000\nprofile=payload.get("https://api.openai.com/profile") or {{}}\nemail=profile.get("email") or payload.get("email")\npath=Path({json.dumps(auth_path)})\ndata=json.load(path.open())\nprofiles=data.get("profiles", {{}})\nchanged=[]\nfor key, prof in profiles.items():\n    if isinstance(prof, dict) and prof.get("provider") == "openai-codex" and prof.get("type") == "oauth":\n        prof["access"]=access\n        prof["refresh"]=refresh\n        prof["expires"]=expires_ms\n        if account_id:\n            prof["accountId"]=account_id\n        if email and key != "openai-codex:default":\n            prof["email"]=email\n        changed.append(key)\nif "openai-codex:default" not in profiles:\n    profiles["openai-codex:default"]={{"type":"oauth","provider":"openai-codex","access":access,"refresh":refresh,"expires":expires_ms}}\n    if account_id:\n        profiles["openai-codex:default"]["accountId"]=account_id\n    changed.append("openai-codex:default")\nif "lastGood" in data and isinstance(data["lastGood"], dict):\n    if email and f"openai-codex:{{email}}" in profiles:\n        data["lastGood"]["openai-codex"] = f"openai-codex:{{email}}"\n    else:\n        data["lastGood"]["openai-codex"] = "openai-codex:default"\nwith path.open("w") as f:\n    json.dump(data, f, indent=2)\n    f.write("\\n")\nprint(json.dumps({{"changed": changed, "expires": expires_ms, "email": email, "accountId": account_id}}))'''
        write = subprocess.run(['docker', 'exec', container, 'python3', '-c', patch_code], text=True, capture_output=True)
        if write.returncode != 0:
            row['status'] = 'write_failed'
            row['error'] = (write.stderr or write.stdout).strip()
        else:
            row['write_result'] = json.loads(write.stdout)
    results.append(row)

all_ok = all(row.get('status') == 'ok' for row in results)

if json_mode:
    print(json.dumps({'checked_at_ms': now_ms, 'dry_run': dry_run, 'results': results}, indent=2))
else:
    mode = 'dry-run' if dry_run else 'apply'
    print(f'=== host-sync-openclaw-codex-auth ({mode}) ===')
    print(f'host auth: {os.environ["TMP_CODEX_AUTH"]}')
    print(f'targets: {" ".join(ids)}')
    for row in results:
        if row.get('status') != 'ok':
            detail = f": {row.get('error')}" if row.get('error') else ''
            print(f"- oc{row['id']}: {row['status']}{detail}")
            continue
        action = 'would update' if dry_run else 'updated'
        changed = ', '.join(row.get('changed_profiles', []))
        print(f"- oc{row['id']}: {action}; hours {row['current_hours_left']} -> {row['host_hours_left']}; refresh_present {row['current_refresh_present']} -> {row['host_refresh_present']}; profiles [{changed}]")

sys.exit(0 if all_ok else 1)
PY

if [[ "$DRY_RUN" -eq 0 && "$RESTART" -eq 1 ]]; then
  echo
  echo "=== Restart staggered ==="
  for id in "${IDS[@]}"; do
    c="openclaw-openclaw-gateway-${id}-1"
    echo "restart oc${id}"
    docker restart "$c" >/dev/null
    sleep "$RESTART_DELAY"
  done
elif [[ "$DRY_RUN" -eq 0 ]]; then
  echo
  echo "Skipping restarts (--no-restart)."
fi

echo

echo "Backups: $WORKDIR/backups"
echo "Set KEEP_WORKDIR=1 to preserve temporary files after exit."
