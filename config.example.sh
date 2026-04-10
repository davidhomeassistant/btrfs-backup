#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# btrfs-backup-rotate  —  per-host configuration
#
# HOW TO USE:
#   1. Copy this file to  configs/<hostname>.sh
#   2. Fill in your real values
#   3. configs/*.sh is gitignored — your tokens never go to git
# ──────────────────────────────────────────────────────────────────────────────

# ── This host ────────────────────────────────────────────────────────────────
HOSTNAME_ID="hypervisor1"               # shown in Telegram & logs

# ── Telegram ─────────────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN=""                    # from @BotFather, leave empty to disable
TELEGRAM_CHAT_ID=""                      # chat or group id

# ── Retention ────────────────────────────────────────────────────────────────
KEEP_LOCAL=2                             # snapshots to keep in source
KEEP_ARCHIVE=0                           # snapshots to keep in archive (0 = all)

# ── Jobs ─────────────────────────────────────────────────────────────────────
# MODE is "local" or "remote" (never both):
#   local  = move old snapshots to another disk on THIS host
#   remote = send old snapshots to ANOTHER host via SSH
#
# For local  → set SOURCE, ARCHIVE
# For remote → set SOURCE, REMOTE_HOST, REMOTE_USER, REMOTE_PATH

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
