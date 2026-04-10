# btrfs-backup-rotate

BTRFS snapshot rotation, archival, and remote replication for KVM hypervisors with Telegram notifications.

## What it does

1. Scans a source directory for date-named BTRFS snapshots (`YYYY_MM_DD`).
2. Keeps the **N most recent** in place (configurable via `KEEP_LOCAL`).
3. Sends older snapshots to a **local archive** volume via `btrfs send/receive` (incremental when possible).
4. Optionally sends snapshots to a **remote host** over SSH.
5. Deletes source snapshots **only after** the copy is verified.
6. Sends a summary to **Telegram** (success or failure, with host identification).

## Safety

- **`--dry-run`** — shows every command without executing anything. Use this first.
- **Lock file** — prevents concurrent runs on the same host.
- **Verify after send** — every `btrfs send` is followed by an existence check before the source is deleted.
- **Incremental sends** — automatically finds the best common parent between source and target.
- **Partial cleanup** — if a send fails mid-way the partial subvolume is removed from the target.

## Quick start

```bash
# 1. Clone to each hypervisor
git clone https://github.com/davidhomeassistant/btrfs-backup.git /opt/btrfs-backup
cd /opt/btrfs-backup

# 2. Install (creates config + daily cron)
./install.sh

# 3. Dry-run first (always!)
./btrfs-backup-rotate.sh -c configs/$(hostname).sh --dry-run --verbose

# 4. Real run
./btrfs-backup-rotate.sh -c configs/$(hostname).sh
```

## Configuration

See [`config.example.sh`](config.example.sh) for the template.

| Variable | Required | Default | Description |
|---|---|---|---|
| `HOSTNAME_ID` | yes | — | Name for this host (shown in Telegram & logs) |
| `TELEGRAM_BOT_TOKEN` | no | `""` | Telegram Bot API token |
| `TELEGRAM_CHAT_ID` | no | `""` | Telegram chat / group ID |
| `KEEP_LOCAL` | yes | `2` | Snapshots to keep in source |
| `KEEP_ARCHIVE` | no | `0` | Snapshots to keep in archive (`0` = unlimited) |

### Job definitions

Each job is **either local or remote** (never both):

- **local** — move old snapshots to another disk on this host
- **remote** — send old snapshots to another host via SSH

You pick the job name — it can be anything (your PC name, VM name, whatever you want). Then prefix the variables with that name:

```bash
JOBS=("mypc" "myvm")

# mypc — remote mode
mypc_MODE="remote"
mypc_SOURCE="/work/backup"
mypc_REMOTE_HOST="192.168.1.100"
mypc_REMOTE_USER="root"
mypc_REMOTE_PATH="/backup/mypc"

# myvm — local mode
myvm_MODE="local"
myvm_SOURCE="/data/backup"
myvm_ARCHIVE="/backuparchive/myvm"
```

| Variable | When | Description |
|---|---|---|
| `<name>_MODE` | always | `"local"` or `"remote"` |
| `<name>_SOURCE` | always | Directory with `YYYY_MM_DD` snapshots |
| `<name>_ARCHIVE` | local | Target path on another BTRFS disk |
| `<name>_REMOTE_HOST` | remote | IP or hostname of the target server |
| `<name>_REMOTE_USER` | remote | SSH user on the target server |
| `<name>_REMOTE_PATH` | remote | Path on the target server |

## CLI flags

```
-c, --config FILE   Path to config file (required)
-n, --dry-run       Preview changes without executing
-v, --verbose       Debug-level logging
-j, --job NAME      Run only a specific job (repeatable)
-h, --help          Show usage
--version           Print version
```

## How incremental send works

The script automatically finds the best **parent snapshot** — the most recent snapshot that exists in both the source and the target — and uses `btrfs send -p <parent>` for an incremental transfer. If no common parent exists (first run), it falls back to a full send.

## Telegram setup

1. Talk to [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. Add the bot to your notification chat/group.
3. Get the chat ID: `curl https://api.telegram.org/bot<TOKEN>/getUpdates` → look for `chat.id`.
4. Put both values in your host config.

Notifications look like:

```
✅ [server2] Backup rotation: OK

• mypc: sent=1 deleted=1 kept=2 → 192.168.1.100
• myvm: archived=1 deleted=1 kept=2
```

## Requirements

- `btrfs-progs` (provides `btrfs` CLI)
- `bash` ≥ 4.0 (for `mapfile`)
- `curl` (for Telegram)
- SSH key-based auth to remote hosts (for remote mode)
- Run as **root** (btrfs send/receive requires it)
