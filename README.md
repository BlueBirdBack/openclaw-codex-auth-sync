# openclaw-codex-auth-sync

Utilities for checking and syncing OpenClaw's cached OpenAI Codex OAuth state across multiple Docker gateway containers.

## Why this exists

In some OpenClaw multi-container setups, renewing the host Codex login in `~/.codex/auth.json` is not enough.
Each OpenClaw agent can keep using its own cached OAuth profile in:

`/home/node/.openclaw/agents/main/agent/auth-profiles.json`

That can leave agents broken with errors like:

- `OAuth token refresh failed`
- `refresh_token_reused`

These scripts help inspect that state and sync a known-good profile across a set of OpenClaw containers.

## Included scripts

### `host-sync-openclaw-codex-auth.sh`

Syncs fresh tokens from the host Codex CLI auth file (`~/.codex/auth.json` by default) into OpenClaw's cached agent auth profiles.

What it does:
- reads host-side Codex OAuth from `~/.codex/auth.json`
- patches all OpenClaw `openai-codex` oauth profiles in each target container
- creates per-container backups before editing
- optionally restarts containers staggered

Quick fix for oc1-oc6:

```bash
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
```

Quick fix without restart:

```bash
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --no-restart
```

### `check-openclaw-codex-expiry.sh`

Checks cached Codex token expiry across selected OpenClaw containers.

What it does:
- inspects `openai-codex:default` expiry in each target container
- flags `healthy`, `expiring_soon`, `expired`, `no_token`, or `down`
- supports `--threshold-hours`
- supports `--json`
- can optionally alert via Telegram with explicit `--telegram-token` and `--chat-id`

Examples:

```bash
./check-openclaw-codex-expiry.sh --ids "1 2 3 4 5 6"
./check-openclaw-codex-expiry.sh --ids "1 2 3 4 5 6" --threshold-hours 24 --json
```

### `check-openclaw-codex-auth.sh`

Checks Codex auth health for a chosen set of OpenClaw Docker gateways.

What it does:
- inspects stored `auth-profiles.json` metadata
- checks whether the default profile exists and is expired
- optionally runs a live OpenClaw probe
- classifies targets as `healthy`, `expired`, `broken`, `drift`, or `missing`

Examples:

```bash
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
./check-openclaw-codex-auth.sh --ids "7 8 9 10 11" --json
```

### `sync-openclaw-codex-auth.sh`

Repairs/syncs Codex OAuth across a chosen set of OpenClaw Docker gateways.

What it does:
- reads a source profile from one container's `auth-profiles.json`
- selects the freshest usable `openai-codex` profile
- patches both `openai-codex:default` and the named source profile in targets
- backs up each target file before patching
- restarts containers with a staggered delay
- verifies the results afterward

Examples:

```bash
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-id 1
./sync-openclaw-codex-auth.sh --ids "7 8 9 10 11" --dry-run
```

## Requirements

- Docker
- Python 3
- OpenClaw installed in the containers
- container naming that matches `openclaw-openclaw-gateway-<id>-1`

## Important notes

- `--ids` is required. This avoids accidental patches to the wrong container set.
- `host-sync-openclaw-codex-auth.sh` is the fastest path after re-authenticating Codex on the host.
- `host-sync-openclaw-codex-auth.sh` now supports `--dry-run` and `--json` for previewing changes before patching.
- `sync-openclaw-codex-auth.sh` is useful when one OpenClaw container already has a known-good cached profile to copy from.
- `check-openclaw-codex-expiry.sh` is the generic early-warning monitor for stale cached tokens.
- These scripts sync OpenClaw's cached auth profiles.
- They do not renew your host Codex login for you.
- If your host `~/.codex/auth.json` is stale, re-authenticate first.

## Safety

- review the target IDs before running
- use `--dry-run` first when possible
- keep the generated backups if you are testing on production gateways

---

Maintained by Nova ✨ (Hermes)
