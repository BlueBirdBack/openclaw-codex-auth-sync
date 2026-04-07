#!/usr/bin/env bash
set -euo pipefail

IDS=()
PROBE=1
JSON_MODE=0
PROBE_TIMEOUT_MS=5000

usage() {
  cat <<'EOF'
Usage: check-openclaw-codex-auth.sh [options]

Inspect Codex auth health for OpenClaw Docker gateways.

This script checks two layers:
1. Stored auth metadata in auth-profiles.json
2. Live OpenClaw probe for the active default profile (and a fallback named profile when needed)

Options:
  --ids "1 2 3 4 5 6"    Space-separated container ids to inspect (required)
  --no-probe             Skip live OpenClaw probes; only inspect stored auth metadata
  --probe-timeout-ms N   Per-probe timeout passed to OpenClaw (default: 5000)
  --json                 Output JSON instead of a text table
  -h, --help             Show this help

Verdicts:
  healthy   default profile valid + live probe ok
  expired   default profile exists but expires <= now
  broken    default profile looks valid but live probe failed
  drift     default profile failed, but a fresher named openai-codex profile probed ok
  missing   default profile missing entirely
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ids)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ids" >&2; exit 2; }
      read -r -a IDS <<< "$1"
      ;;
    --no-probe)
      PROBE=0
      ;;
    --probe-timeout-ms)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --probe-timeout-ms" >&2; exit 2; }
      PROBE_TIMEOUT_MS="$1"
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

command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 2; }

export IDS_STR="${IDS[*]}"
export PROBE JSON_MODE PROBE_TIMEOUT_MS

if [[ ${#IDS[@]} -eq 0 ]]; then
  echo "You must pass --ids, for example: --ids "1 2 3 4 5 6"" >&2
  exit 2
fi

python3 - <<'PY'
import json
import os
import subprocess
import sys
import time
from typing import Any

IDS = [x for x in os.environ.get("IDS_STR", "").split() if x]
PROBE = os.environ.get("PROBE", "1") == "1"
JSON_MODE = os.environ.get("JSON_MODE", "0") == "1"
PROBE_TIMEOUT_MS = int(os.environ.get("PROBE_TIMEOUT_MS", "5000"))
AUTH_PATH="/home/node/.openclaw/agents/main/agent/auth-profiles.json"


def run(cmd: list[str], timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as e:
        stdout = e.stdout.decode(errors="replace") if isinstance(e.stdout, (bytes, bytearray)) else (e.stdout or "")
        stderr = e.stderr.decode(errors="replace") if isinstance(e.stderr, (bytes, bytearray)) else (e.stderr or "")
        return subprocess.CompletedProcess(
            cmd,
            124,
            stdout=stdout,
            stderr=stderr + f"\nTIMEOUT after {timeout}s",
        )


def read_auth_doc(container: str) -> tuple[dict[str, Any] | None, str | None]:
    cp = run(["docker", "exec", container, "cat", AUTH_PATH], timeout=15)
    if cp.returncode != 0:
        return None, (cp.stderr or cp.stdout or f"cat failed rc={cp.returncode}").strip()
    try:
        return json.loads(cp.stdout), None
    except Exception as e:
        return None, f"json parse failed: {e}"


def get_profile_meta(doc: dict[str, Any]) -> dict[str, Any]:
    profiles = doc.get("profiles", {}) or {}
    default = profiles.get("openai-codex:default") or {}
    now_ms = int(time.time() * 1000)
    exp = default.get("expires") or 0
    refresh = default.get("refresh") or ""
    email = default.get("email")
    account_id = default.get("accountId")
    named = []
    for key, value in profiles.items():
        if not key.startswith("openai-codex:") or key == "openai-codex:default":
            continue
        if not isinstance(value, dict):
            continue
        named.append({
            "profileId": key,
            "expires": value.get("expires") or 0,
            "email": value.get("email"),
            "accountId": value.get("accountId"),
            "hasRefresh": bool(value.get("refresh")),
            "sameAsDefault": bool(refresh) and (value.get("refresh") == refresh) and ((value.get("expires") or 0) == exp) and (value.get("email") == email) and (value.get("accountId") == account_id),
        })
    named.sort(key=lambda x: x.get("expires", 0), reverse=True)
    freshest_named = named[0] if named else None
    return {
        "hasProfile": bool(default),
        "hasRefresh": bool(refresh),
        "expiresAt": exp,
        "hoursLeft": int((exp - now_ms) / 3600000) if exp and exp > now_ms else -1,
        "status": "valid" if exp and exp > now_ms else "expired",
        "accountId": account_id,
        "email": email,
        "refreshPrefix": (refresh[:16] + "...") if refresh else "",
        "namedProfiles": named,
        "freshestNamedProfile": freshest_named,
    }


def extract_json_payload(text: str) -> str | None:
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.lstrip().startswith("{"):
            start = i
            break
    if start is None:
        return None
    candidate = "\n".join(lines[start:]).strip()
    last = candidate.rfind("}")
    if last == -1:
        return None
    return candidate[: last + 1]


def probe_profile(container: str, profile_id: str) -> tuple[dict[str, Any] | None, str | None]:
    cmd = [
        "docker", "exec", container,
        "openclaw", "models", "status",
        "--json",
        "--probe",
        "--probe-provider", "openai-codex",
        "--probe-profile", profile_id,
        "--probe-timeout", str(PROBE_TIMEOUT_MS),
    ]
    cp = run(cmd, timeout=max(90, int(PROBE_TIMEOUT_MS / 1000) * 10 + 40))
    stdout = cp.stdout.strip()
    if cp.returncode != 0 and not stdout:
        return None, (cp.stderr or f"probe failed rc={cp.returncode}").strip()
    payload = extract_json_payload(stdout)
    if not payload:
        return None, f"probe json not found; stdout={stdout[:300]}"
    try:
        data = json.loads(payload)
    except Exception as e:
        return None, f"probe json parse failed: {e}; stdout={stdout[:300]}"
    results = (((data.get("auth") or {}).get("probes") or {}).get("results") or [])
    match = None
    for item in results:
        if item.get("profileId") == profile_id:
            match = item
            break
    if match is None and results:
        match = results[0]
    if match is None:
        return None, "no probe result"
    return {
        "profileId": profile_id,
        "status": match.get("status", "unknown"),
        "error": match.get("error"),
        "latencyMs": match.get("latencyMs"),
        "model": match.get("model"),
    }, None


def classify(meta: dict[str, Any], default_probe: dict[str, Any] | None, named_probe: dict[str, Any] | None) -> tuple[str, str]:
    if not meta["hasProfile"]:
        return "missing", "default profile missing"
    if meta["status"] == "expired":
        return "expired", "default profile expired"
    if not meta["hasRefresh"]:
        return "broken", "default profile missing refresh token"
    if not PROBE:
        return "profile-valid", "probe skipped"
    if default_probe and default_probe.get("status") == "ok":
        return "healthy", "default profile probe ok"
    if named_probe and named_probe.get("status") == "ok":
        named = meta.get("freshestNamedProfile") or {}
        if named.get("sameAsDefault"):
            return "healthy", f'default probe={default_probe.get("status") if default_probe else "unknown"}; equivalent named profile {named_probe.get("profileId")} probe ok'
        return "drift", f'default probe={default_probe.get("status") if default_probe else "unknown"}; named profile {named_probe.get("profileId")} probe ok'
    if default_probe:
        err = default_probe.get("error") or "probe failed"
        return "broken", err
    return "broken", "default probe unavailable"


rows = []
overall = 0
for raw_id in IDS:
    cid = str(raw_id)
    container = f"openclaw-openclaw-gateway-{cid}-1"
    row: dict[str, Any] = {
        "instance": f"oc{cid}",
        "container": container,
    }

    doc, auth_err = read_auth_doc(container)
    if auth_err or doc is None:
        row.update({
            "defaultProfile": False,
            "probeDefault": "not-run",
            "probeNamed": "not-run",
            "verdict": "missing",
            "note": auth_err or "auth doc missing",
        })
        rows.append(row)
        overall = max(overall, 2)
        continue

    meta = get_profile_meta(doc)
    row.update({
        "defaultProfile": meta["hasProfile"],
        "expiresAt": meta["expiresAt"],
        "hoursLeft": meta["hoursLeft"],
        "refreshPresent": meta["hasRefresh"],
        "accountId": meta["accountId"],
        "email": meta["email"],
        "refreshPrefix": meta["refreshPrefix"],
        "namedProfiles": meta["namedProfiles"],
        "freshestNamedProfile": meta["freshestNamedProfile"],
    })

    default_probe = None
    named_probe = None
    probe_errors = []

    if PROBE and meta["hasProfile"] and meta["hasRefresh"] and meta["status"] == "valid":
        default_probe, err = probe_profile(container, "openai-codex:default")
        if err:
            probe_errors.append(f"default probe: {err}")
        named = meta.get("freshestNamedProfile")
        if default_probe and default_probe.get("status") != "ok" and named and named.get("hasRefresh"):
            named_probe, err = probe_profile(container, named["profileId"])
            if err:
                probe_errors.append(f"named probe: {err}")

    verdict, note = classify(meta, default_probe, named_probe)
    if probe_errors:
        note = "; ".join([note] + probe_errors)

    row.update({
        "probeDefault": (default_probe or {}).get("status", "not-run"),
        "probeDefaultError": (default_probe or {}).get("error"),
        "probeNamed": (named_probe or {}).get("status", "not-run"),
        "probeNamedProfile": (named_probe or {}).get("profileId"),
        "probeNamedError": (named_probe or {}).get("error"),
        "verdict": verdict,
        "note": note,
    })

    severity = {
        "healthy": 0,
        "profile-valid": 1,
        "drift": 1,
        "broken": 2,
        "expired": 2,
        "missing": 2,
    }.get(verdict, 2)
    overall = max(overall, severity)
    rows.append(row)

if JSON_MODE:
    print(json.dumps({
        "checkedAt": int(time.time() * 1000),
        "probeEnabled": PROBE,
        "probeTimeoutMs": PROBE_TIMEOUT_MS,
        "results": rows,
        "exitCode": overall,
    }, indent=2))
    sys.exit(overall)

headers = [
    ("instance", 8),
    ("default", 8),
    ("hours", 7),
    ("refresh", 8),
    ("probe_def", 10),
    ("probe_alt", 10),
    ("verdict", 12),
    ("note", 0),
]


def trunc(text: Any, width: int) -> str:
    s = "" if text is None else str(text)
    if width <= 0:
        return s
    if len(s) <= width:
        return s.ljust(width)
    if width <= 1:
        return s[:width]
    return s[: width - 1] + "…"

header_line = " ".join(trunc(name, width) for name, width in headers if width > 0) + " note"
print(header_line)
print("-" * len(header_line))
for row in rows:
    print(
        f"{trunc(row.get('instance'), 8)} "
        f"{trunc('yes' if row.get('defaultProfile') else 'no', 8)} "
        f"{trunc(row.get('hoursLeft'), 7)} "
        f"{trunc('yes' if row.get('refreshPresent') else 'no', 8)} "
        f"{trunc(row.get('probeDefault'), 10)} "
        f"{trunc(row.get('probeNamed'), 10)} "
        f"{trunc(row.get('verdict'), 12)} "
        f"{row.get('note', '')}"
    )

sys.exit(overall)
PY
