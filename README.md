# Btrfs Backup for KVM VMs

Daily incremental Btrfs backup scripts for KVM virtual machines with Telegram notifications.

Two variants depending on where the long-term backup is stored:

| Script | Long-term target | Example |
|--------|-----------------|---------|
| `kvm-btrfs-backup-local.sh` | Local path on same host | faeton → `/backup/kvm` |
| `kvm-btrfs-backup-remote.sh` | Remote host via SSH | win_b → `root@192.168.12.250:/backup/win_b/` |

## How It Works

1. Creates a **read-only Btrfs snapshot** of the source subvolume
2. Sends it (full or incremental) to the long-term destination
3. Cleans up old short-term snapshots (keeps last N)
4. Sends **Telegram notifications** on start, success, and failure

## Configuration

All settings are variables at the top of each script. Edit them before deploying.

### Common variables (both scripts)

| Variable | Description | Example |
|----------|-------------|---------|
| `BACKUP_NAME` | Label in Telegram messages | `faeton`, `win_b` |
| `SOURCE` | Btrfs subvolume to snapshot | `/work/virt/windows` |
| `SHORT_DIR` | Short-term snapshot directory | `/work/backup` |
| `KEEP_SHORT` | How many short-term snapshots to keep | `2` |
| `LOG_FILE` | Log file path | `/var/log/kvm-btrfs-backup.log` |
| `TG_BOT_TOKEN` | Telegram bot API token | |
| `TG_CHAT_ID` | Telegram chat/group ID | |

### Local script only

| Variable | Description | Example |
|----------|-------------|---------|
| `LONG_DIR` | Local long-term backup path | `/backup/kvm` |

### Remote script only

| Variable | Description | Example |
|----------|-------------|---------|
| `REMOTE_HOST` | SSH target (`user@ip`) | `root@192.168.12.250` |
| `REMOTE_PATH` | Path on remote server | `/backup/win_b/` |
| `SSH_OPTIONS` | SSH connection options | `-o BatchMode=yes ...` |

> **Note:** For the remote script, SSH key-based auth must be set up between the source and remote host (`ssh-copy-id`).

## Installation

1. Copy the appropriate script to the target host:

```bash
# For local backup (e.g. faeton)
scp kvm-btrfs-backup-local.sh root@<host>:/usr/local/bin/kvm-btrfs-backup.sh

# For remote backup (e.g. win_b)
scp kvm-btrfs-backup-remote.sh root@<host>:/usr/local/bin/kvm-btrfs-backup.sh
```

2. Make it executable:

```bash
chmod +x /usr/local/bin/kvm-btrfs-backup.sh
```

3. Edit the variables at the top of the script:

```bash
nano /usr/local/bin/kvm-btrfs-backup.sh
```

4. Test Telegram notification (no backup runs):

```bash
/usr/local/bin/kvm-btrfs-backup.sh --test-notify
```

5. Add to cron (daily at 2:00 AM):

```bash
crontab -e
```

```
0 2 * * * /usr/local/bin/kvm-btrfs-backup.sh >> /var/log/kvm-btrfs-backup.log 2>&1
```

## Usage

```bash
# Run full backup
/usr/local/bin/kvm-btrfs-backup.sh

# Test Telegram only (no backup)
/usr/local/bin/kvm-btrfs-backup.sh --test-notify
```

## Telegram Messages

All messages are prefixed with the `BACKUP_NAME` so you can tell which host sent them:

- `[faeton] Backup Started`
- `[faeton] Backup Completed`
- `[win_b] Backup FAILED` (includes exit code and log path)

## Current Deployments

| Host | Script | BACKUP_NAME | Source | Destination |
|------|--------|-------------|--------|-------------|
| faeton (192.168.15.120) | local | `faeton` | `/work/virt/windows` | `/backup/kvm` |
| server2 (192.168.12.2) | remote | `win_b` | `/work/kvm` | `192.168.12.250:/backup/win_b/` |
