# openclaw-codex-auth-sync

Small shell scripts for one annoying OpenClaw problem:

You re-login Codex on the host, but some OpenClaw containers still use stale cached auth and keep failing.

This repo helps you:
- check host Codex auth
- check container cached auth
- copy fresh host auth into containers
- copy one good container's cached auth into other containers

## The problem in plain English

There are two different auth layers:

1. Host Codex login
   - file: ~/.codex/auth.json
2. OpenClaw container cache
   - file: /home/node/.openclaw/agents/main/agent/auth-profiles.json

Refreshing the host login does not automatically fix the cached container copies.

That is why you can see errors like:
- OAuth token refresh failed
- refresh_token_reused

## Start here

If you just want the shortest path:

1. Check whether the host login is fresh:

```bash
./check-host-codex-auth.sh
```

2. Check whether the containers are stale:

```bash
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
```

3. If the host login is good and the containers are stale, push host auth into the containers:

```bash
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
```

That is the normal fix.

## Which script should I use?

| What you want | Use this |
|---|---|
| Check only the host Codex login | `check-host-codex-auth.sh` |
| Quickly see whether container tokens are expired | `check-openclaw-codex-expiry.sh` |
| Check container auth metadata and optionally do a live probe | `check-openclaw-codex-auth.sh` |
| Copy host `~/.codex/auth.json` into containers | `host-sync-openclaw-codex-auth.sh` |
| Copy one container's cached auth into other containers | `sync-openclaw-codex-auth.sh` |

Rule of thumb:
- host re-login happened recently -> use `host-sync-openclaw-codex-auth.sh`
- one container still works and the others do not -> use `sync-openclaw-codex-auth.sh`

## Common workflows

### 1) Normal fix after re-authenticating Codex on the host

```bash
./check-host-codex-auth.sh
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --dry-run
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
```

### 2) Fast health check across containers

```bash
./check-openclaw-codex-expiry.sh --ids "1 2 3 4 5 6"
```

### 3) Deeper check with live probe

```bash
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
```

If you want a faster metadata-only check, skip the live probe:

```bash
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --no-probe
```

### 4) One container is good, others are bad

Copy the good cached auth from one container to the rest:

```bash
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-id 1 --dry-run
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-id 1
```

## Script reference

### `check-host-codex-auth.sh`

Use this when you care about the host login only.

What it checks:
- reads `~/.codex/auth.json` by default
- decodes access token expiry
- shows hours left
- shows whether a refresh token exists
- reports email/account id when available

Examples:

```bash
./check-host-codex-auth.sh
./check-host-codex-auth.sh --json
./check-host-codex-auth.sh --auth-path /custom/path/auth.json --json
```

### `check-openclaw-codex-expiry.sh`

Fast container check. No live OpenClaw probe.

What it checks:
- reads `openai-codex:default` expiry from each target container
- classifies each target as `healthy`, `expiring_soon`, `expired`, `no_token`, or `down`
- can emit JSON
- can send Telegram alerts if you pass a bot token and chat id

Examples:

```bash
./check-openclaw-codex-expiry.sh --ids "1 2 3 4 5 6"
./check-openclaw-codex-expiry.sh --ids "1 2 3 4 5 6" --threshold-hours 24 --json
```

### `check-openclaw-codex-auth.sh`

Deeper container check. This is slower because it can run a live probe.

What it checks:
- reads stored `auth-profiles.json`
- checks whether the default profile exists
- checks whether the default profile is expired
- can probe OpenClaw live
- classifies targets as `healthy`, `expired`, `broken`, `drift`, or `missing`

Examples:

```bash
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --json
./check-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --json --no-probe
```

Notes:
- `--json` prints after the full run finishes
- `--no-probe` is much faster if you only want stored metadata

### `host-sync-openclaw-codex-auth.sh`

Best default repair path after you refresh Codex on the host.

What it does:
- reads host auth from `~/.codex/auth.json`
- patches OpenClaw `openai-codex` oauth profiles in each target container
- creates a backup for each target before writing
- can do a dry run first
- can skip restarts with `--no-restart`

Examples:

```bash
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6"
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --dry-run
./host-sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --no-restart
```

### `sync-openclaw-codex-auth.sh`

Use this when one container already has a good cached profile and you want to copy that state to other containers.

What it does:
- reads a source profile from one container's `auth-profiles.json`
- picks the freshest usable `openai-codex` profile
- patches both `openai-codex:default` and the selected named source profile in targets
- creates backups before writing
- can dry-run first
- restarts containers with a staggered delay unless you disable that
- verifies the result afterward unless you disable that

Examples:

```bash
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-id 1
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-id 1 --dry-run
./sync-openclaw-codex-auth.sh --ids "1 2 3 4 5 6" --source-profile openai-codex:someone@example.com
```

## Requirements

For `check-host-codex-auth.sh`:
- Python 3

For the Docker/container scripts:
- Docker
- Python 3
- OpenClaw available in the containers
- container names that look like `openclaw-openclaw-gateway-<id>-1`

## Important behavior

- `--ids` is required for the Docker/container scripts. That is deliberate, so you do not patch the wrong set by accident.
- These scripts sync cached OpenClaw auth. They do not log Codex in for you.
- If the host `~/.codex/auth.json` is stale, fix that first.
- `host-sync-openclaw-codex-auth.sh` is usually the first thing to try after host re-auth.
- `sync-openclaw-codex-auth.sh` is for the case where one container already has the good cached state.

## Docker access note

The Docker/container scripts fail fast if Docker exists but your current shell cannot talk to it.

Common fix after adding your user to the `docker` group:

```bash
newgrp docker
```

Or just open a fresh login shell.

## Safety

- review the target ids before you run anything
- use `--dry-run` first when the script supports it
- keep the generated backups if you are touching production gateways

---

Maintained by Nova ✨ (Hermes)
