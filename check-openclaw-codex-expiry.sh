#!/usr/bin/env bash
set -euo pipefail

IDS=()
THRESHOLD_HOURS=48
JSON_MODE=0
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
AUTH_PATH="/home/node/.openclaw/agents/main/agent/auth-profiles.json"

usage() {
  cat <<'EOF'
Usage: check-openclaw-codex-expiry.sh [options]

Check OpenClaw Codex token expiry across selected gateway containers.

Options:
  --ids "1 2 3 4 5 6"     Space-separated container ids to inspect (required)
  --threshold-hours N     Alert threshold in hours (default: 48)
  --json                  Emit machine-readable JSON summary
  --telegram-token TOKEN  Optional Telegram bot token for alerts
  --chat-id ID            Optional Telegram chat id for alerts
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ids)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ids" >&2; exit 2; }
      read -r -a IDS <<< "$1"
      ;;
    --threshold-hours)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --threshold-hours" >&2; exit 2; }
      THRESHOLD_HOURS="$1"
      ;;
    --json)
      JSON_MODE=1
      ;;
    --telegram-token)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --telegram-token" >&2; exit 2; }
      TELEGRAM_TOKEN="$1"
      ;;
    --chat-id)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --chat-id" >&2; exit 2; }
      CHAT_ID="$1"
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
[[ ${#IDS[@]} -gt 0 ]] || { echo 'You must pass --ids, for example: --ids "1 2 3 4 5 6"' >&2; exit 2; }

export IDS_STR="${IDS[*]}" THRESHOLD_HOURS JSON_MODE AUTH_PATH TELEGRAM_TOKEN CHAT_ID
python3 - <<'PY'
import json, os, subprocess, sys, time, urllib.parse, urllib.request

ids = [x for x in os.environ.get('IDS_STR', '').split() if x]
threshold_hours = int(os.environ.get('THRESHOLD_HOURS', '48'))
json_mode = os.environ.get('JSON_MODE') == '1'
auth_path = os.environ['AUTH_PATH']
telegram_token = os.environ.get('TELEGRAM_TOKEN') or ''
chat_id = os.environ.get('CHAT_ID') or ''
now_ms = int(time.time() * 1000)
threshold_ms = now_ms + threshold_hours * 3600 * 1000
results = []
problems = []

for cid in ids:
    container = f'openclaw-openclaw-gateway-{cid}-1'
    row = {'id': cid, 'container': container}
    inspect = subprocess.run(['docker', 'inspect', '-f', '{{.State.Running}}', container], text=True, capture_output=True)
    if inspect.returncode != 0 or inspect.stdout.strip() != 'true':
        row['status'] = 'down'
        problems.append(f'oc{cid}: down')
        results.append(row)
        continue
    cmd = [
        'docker', 'exec', container, 'python3', '-c',
        f"import json; d=json.load(open('{auth_path}')); p=d.get('profiles',{{}}).get('openai-codex:default',{{}}); print(json.dumps({{'expires': p.get('expires', 0), 'email': p.get('email'), 'accountId': p.get('accountId')}}))"
    ]
    cp = subprocess.run(cmd, text=True, capture_output=True)
    if cp.returncode != 0:
        row['status'] = 'read_failed'
        row['error'] = (cp.stderr or cp.stdout).strip()
        problems.append(f'oc{cid}: read failed')
        results.append(row)
        continue
    info = json.loads(cp.stdout)
    exp = int(info.get('expires') or 0)
    row['expires'] = exp
    row['email'] = info.get('email')
    row['accountId'] = info.get('accountId')
    if exp <= 0:
        row['status'] = 'no_token'
        problems.append(f'oc{cid}: no token')
    elif exp < now_ms:
        row['status'] = 'expired'
        problems.append(f'oc{cid}: expired')
    elif exp < threshold_ms:
        row['status'] = 'expiring_soon'
        row['hours_left'] = int((exp - now_ms) / 3600000)
        problems.append(f"oc{cid}: {row['hours_left']}h left")
    else:
        row['status'] = 'healthy'
        row['hours_left'] = int((exp - now_ms) / 3600000)
    results.append(row)

if telegram_token and chat_id and problems:
    summary_lines = ['🔑 Codex OAuth Alert', '']
    for row in results:
        extra = f" ({row['hours_left']}h left)" if 'hours_left' in row else ''
        summary_lines.append(f"oc{row['id']}: {row['status']}{extra}")
    summary_lines += ['', f"Fix: ./host-sync-openclaw-codex-auth.sh --ids \"{' '.join(ids)}\""]
    data = urllib.parse.urlencode({'chat_id': chat_id, 'text': '\n'.join(summary_lines)}).encode()
    urllib.request.urlopen(f'https://api.telegram.org/bot{telegram_token}/sendMessage', data=data, timeout=10).read()

if json_mode:
    print(json.dumps({'checked_at_ms': now_ms, 'threshold_hours': threshold_hours, 'results': results}, indent=2))
else:
    for row in results:
        extra = f" ({row['hours_left']}h left)" if 'hours_left' in row else ''
        print(f"oc{row['id']}: {row['status']}{extra}")

sys.exit(1 if problems else 0)
PY
