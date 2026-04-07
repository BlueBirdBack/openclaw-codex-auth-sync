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

### `check-2632-codex-auth.sh`

Checks Codex auth health for a group of OpenClaw Docker gateways.

What it does:
- inspects stored `auth-profiles.json` metadata
- checks whether the default profile exists and is expired
- optionally runs a live OpenClaw probe
- classifies targets as `healthy`, `expired`, `broken`, `drift`, or `missing`

Example:

```bash
./check-2632-codex-auth.sh --ids "7 8 9 10 11"
./check-2632-codex-auth.sh --ids "7 8 9 10 11" --json
```

### `fix-codex-auth-v4.sh`

Repairs/syncs Codex OAuth across a group of OpenClaw Docker gateways.

What it does:
- reads a source profile from one container's `auth-profiles.json`
- selects the freshest usable `openai-codex` profile
- patches both `openai-codex:default` and the named source profile in targets
- backs up each target file before patching
- restarts containers with a staggered delay
- verifies the results afterward

Example:

```bash
./fix-codex-auth-v4.sh --ids "7 8 9 10 11" --source-id 7
```

Dry run:

```bash
./fix-codex-auth-v4.sh --ids "7 8 9 10 11" --source-id 7 --dry-run
```

## Requirements

- Docker
- Python 3
- OpenClaw installed in the containers
- container naming that matches `openclaw-openclaw-gateway-<id>-1`

## Important note

These scripts sync OpenClaw's cached auth profiles.
They do not renew your host Codex login for you.
If your host `~/.codex/auth.json` is stale, re-authenticate first.

## Safety

- review the target IDs before running
- use `--dry-run` first when possible
- keep the generated backups if you are testing on production gateways
