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
KEEP_ARCHIVE=0       # how many to keep in the archive, only for local mode (0 = unlimited)

# ── Log file (optional) ─────────────────────────────────────────────────────
# LOG_FILE="/var/log/btrfs-backup.log"

# ── Backup jobs ──────────────────────────────────────────────────────────────
# List your job names here, then define each one below.
#
# Each job has a MODE — either "local" or "remote" (never both):
#   local  = archive snapshots to another HDD on THIS host
#   remote = send snapshots to ANOTHER host via SSH
#
JOBS=("win_b" "linux_vm")

# --- Job: win_b ---
# Sends snapshots to a remote host via SSH.
win_b_SOURCE="/work/backup"
win_b_MODE="remote"
win_b_REMOTE="root@192.168.12.250:/backup/win_b"

# --- Job: linux_vm ---
# Archives snapshots to a local BTRFS volume (different HDD).
linux_vm_SOURCE="/data/backup"
linux_vm_MODE="local"
linux_vm_ARCHIVE="/backuparchive/linux_vm"
