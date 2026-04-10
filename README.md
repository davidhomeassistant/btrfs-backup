# btrfs-backup-rotate

BTRFS snapshot rotation, archival, and remote replication for KVM hypervisors with Telegram notifications.

## What it does

1. Scans a source directory for date-named BTRFS snapshots (`YYYY_MM_DD`).
2. Keeps the **N most recent** in place (configurable via `KEEP_LOCAL`).
3. Sends older snapshots to a **local archive** volume via `btrfs send/receive` (incremental when possible).
4. Optionally replicates snapshots to a **remote host** over SSH.
5. Deletes source snapshots **only after** the archive copy is verified.
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
git clone git@github.com:YOUR_USER/btrfs-backup.git /opt/btrfs-backup
cd /opt/btrfs-backup

# 2. Create a host config
mkdir -p configs
cp config.example.sh configs/$(hostname).sh
vim configs/$(hostname).sh   # fill in real paths & Telegram token

# 3. Dry-run first (always!)
./btrfs-backup-rotate.sh -c configs/$(hostname).sh --dry-run --verbose

# 4. Real run
./btrfs-backup-rotate.sh -c configs/$(hostname).sh

# 5. Add to cron (e.g. daily at 03:00)
echo "0 3 * * * root /opt/btrfs-backup/btrfs-backup-rotate.sh -c /opt/btrfs-backup/configs/\$(hostname).sh >> /var/log/btrfs-backup-cron.log 2>&1" \
  > /etc/cron.d/btrfs-backup
```

## Configuration

See [`config.example.sh`](config.example.sh) for a fully commented template.

| Variable | Required | Default | Description |
|---|---|---|---|
| `HOSTNAME_ID` | yes | — | Label used in logs and Telegram messages |
| `TELEGRAM_BOT_TOKEN` | no | `""` | Telegram Bot API token |
| `TELEGRAM_CHAT_ID` | no | `""` | Telegram chat / group ID |
| `KEEP_LOCAL` | yes | `2` | Snapshots to keep in source |
| `KEEP_ARCHIVE` | no | `0` | Snapshots to keep in archive (`0` = unlimited) |
| `LOG_FILE` | no | `/var/log/btrfs-backup.log` | Log file path |
| `BACKUP_JOBS` | yes | — | Array of job specs (see below) |

### Job definitions

List job names in `JOBS`, then define each one below. Each job is **either local or remote** (never both):

- **local** — move old snapshots to another disk on this host
- **remote** — send old snapshots to another host via SSH

```bash
JOBS=("win_b" "linux_vm")

# --- win_b: send to remote host ---
win_b_MODE="remote"
win_b_SOURCE="/work/backup"
win_b_REMOTE_HOST="192.168.12.250"
win_b_REMOTE_USER="root"
win_b_REMOTE_PATH="/backup/win_b"

# --- linux_vm: archive to local disk ---
linux_vm_MODE="local"
linux_vm_SOURCE="/data/backup"
linux_vm_ARCHIVE="/backuparchive/linux_vm"
```

| Variable | When | Description |
|---|---|---|
| `<job>_MODE` | always | `"local"` or `"remote"` |
| `<job>_SOURCE` | always | Directory with `YYYY_MM_DD` snapshots |
| `<job>_ARCHIVE` | local | Target path on another BTRFS disk |
| `<job>_REMOTE_HOST` | remote | IP or hostname of the target server |
| `<job>_REMOTE_USER` | remote | SSH user on the target server |
| `<job>_REMOTE_PATH` | remote | Path on the target server |

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
✅ [hypervisor1] Backup rotation: OK

• win_b: archived=1 deleted=1 kept=2
• win_b: remote_sent=1 → 192.168.12.250
• linux_vm: archived=1 deleted=1 kept=2
```

## File layout

```
btrfs-backup/
├── btrfs-backup-rotate.sh   # main script (deploy everywhere)
├── config.example.sh        # template (committed to git)
├── configs/                  # per-host configs (gitignored)
│   ├── hypervisor1.sh
│   └── hypervisor2.sh
├── .gitignore
└── README.md
```

## Requirements

- `btrfs-progs` (provides `btrfs` CLI)
- `bash` ≥ 4.0 (for `mapfile`)
- `curl` (for Telegram)
- SSH key-based auth to remote hosts (for remote replication)
- Run as **root** (btrfs send/receive requires it)
