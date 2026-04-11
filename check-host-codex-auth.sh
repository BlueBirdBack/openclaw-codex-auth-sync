#!/usr/bin/env bash
set -euo pipefail

JSON_MODE=0
CODEX_AUTH_PATH="${CODEX_AUTH_PATH:-$HOME/.codex/auth.json}"

usage() {
  cat <<'EOF'
Usage: check-host-codex-auth.sh [options]

Inspect the host Codex CLI auth file directly.

This script reads ~/.codex/auth.json (or --auth-path) and reports:
- access token expiry
- hours left
- refresh token presence
- host email/account id when available

Options:
  --auth-path PATH   Host Codex auth.json path (default: ~/.codex/auth.json)
  --json             Emit machine-readable JSON output
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-path)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --auth-path" >&2; exit 2; }
      CODEX_AUTH_PATH="$1"
      ;;
    --json)
      JSON_MODE=1
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

command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 2; }
[[ -f "$CODEX_AUTH_PATH" ]] || { echo "Host auth file not found: $CODEX_AUTH_PATH" >&2; exit 2; }

export CODEX_AUTH_PATH JSON_MODE
python3 - <<'PY'
import base64
import datetime as dt
import json
import os
import sys
import time
from typing import Any

path = os.environ["CODEX_AUTH_PATH"]
json_mode = os.environ.get("JSON_MODE") == "1"
now = time.time()


def fail(message: str, code: int = 2) -> None:
    if json_mode:
        print(json.dumps({"status": "error", "error": message, "auth_file": path}, indent=2))
    else:
        print(message, file=sys.stderr)
    sys.exit(code)

try:
    with open(path) as f:
        doc = json.load(f)
except Exception as e:
    fail(f"Failed to read {path}: {e}")

tokens = doc.get("tokens") or {}
access = tokens.get("access_token")
refresh = tokens.get("refresh_token")
account_id = tokens.get("account_id")
if not access:
    fail(f"Missing tokens.access_token in {path}")

parts = access.split(".")
if len(parts) < 2:
    fail("Host access token is not a JWT-like token")

payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(payload_b64.encode()).decode())
except Exception as e:
    fail(f"Failed to decode JWT payload: {e}")

exp = payload.get("exp")
if not exp:
    fail("Decoded host access token has no exp claim")

profile = payload.get("https://api.openai.com/profile") or {}
email = profile.get("email") or payload.get("email")
expires_at_utc = dt.datetime.fromtimestamp(int(exp), tz=dt.timezone.utc)
hours_left = round((int(exp) - now) / 3600, 2)
status = "valid" if int(exp) > now else "expired"
result: dict[str, Any] = {
    "auth_file": path,
    "status": status,
    "hours_left": hours_left,
    "expires_at_utc": expires_at_utc.isoformat().replace("+00:00", "Z"),
    "email": email,
    "account_id": account_id,
    "refresh_present": bool(refresh),
    "last_refresh": doc.get("last_refresh"),
    "auth_mode": doc.get("auth_mode"),
}

if json_mode:
    print(json.dumps(result, indent=2))
else:
    print(f"auth_file: {result['auth_file']}")
    print(f"status: {result['status']}")
    print(f"hours_left: {result['hours_left']}")
    print(f"expires_at_utc: {result['expires_at_utc']}")
    print(f"email: {result['email']}")
    print(f"account_id: {result['account_id']}")
    print(f"refresh_present: {'yes' if result['refresh_present'] else 'no'}")
    print(f"last_refresh: {result['last_refresh']}")
    print(f"auth_mode: {result['auth_mode']}")

sys.exit(0 if status == "valid" else 1)
PY
