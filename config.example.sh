#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# btrfs-backup-rotate  —  per-host configuration
#
# HOW TO USE:
#   1. Copy this file to  configs/<hostname>.sh
#   2. Fill in your real values
#   3. This file is sourced by the script, so standard bash syntax applies
#   4. configs/*.sh is gitignored — your tokens stay out of the repo
# ──────────────────────────────────────────────────────────────────────────────

# ── Host identifier ──────────────────────────────────────────────────────────
# This name appears in Telegram messages and logs so you know WHICH host
# sent the notification.
HOSTNAME_ID="hypervisor1"

# ── Telegram notifications ───────────────────────────────────────────────────
# 1. Talk to @BotFather on Telegram → /newbot → you get TELEGRAM_BOT_TOKEN
# 2. Add the bot to your chat/group
# 3. Open https://api.telegram.org/bot<TOKEN>/getUpdates → find chat.id
# 4. Put both values here
#
# Leave empty to disable notifications entirely.
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── Retention ────────────────────────────────────────────────────────────────
KEEP_LOCAL=2         # how many snapshots to keep in the source directory
KEEP_ARCHIVE=0       # how many to keep in the archive (0 = unlimited)

# ── Log file (optional) ─────────────────────────────────────────────────────
# LOG_FILE="/var/log/btrfs-backup.log"

# ── Backup jobs ──────────────────────────────────────────────────────────────
# List your job names here, then define each one below with clear variables.
JOBS=("win_b" "linux_vm")

# --- Job: win_b ---
# Archives locally AND replicates to a remote host.
win_b_SOURCE="/work/backup"                          # where snapshots live
win_b_ARCHIVE="/backuparchive/win_b"                 # local archive (different HDD)
win_b_REMOTE="root@192.168.12.250:/backup/win_b"     # remote host (optional, can be empty)

# --- Job: linux_vm ---
# Archives locally only, no remote.
linux_vm_SOURCE="/data/backup"
linux_vm_ARCHIVE="/backuparchive/linux_vm"
linux_vm_REMOTE=""
