#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# btrfs-backup-rotate config
#
# 1. Copy to configs/<hostname>.sh
# 2. Fill in YOUR values below
# 3. configs/*.sh is gitignored — tokens stay out of git
# ──────────────────────────────────────────────────────────────────────────────

HOSTNAME_ID=""                           # name for this host (shown in Telegram)

TELEGRAM_BOT_TOKEN=""                    # from @BotFather, leave empty to disable
TELEGRAM_CHAT_ID=""                      # chat or group id

KEEP_LOCAL=2                             # snapshots to keep in source
KEEP_ARCHIVE=0                           # snapshots to keep in archive (0 = all)

# ── Jobs ─────────────────────────────────────────────────────────────────────
#
# 1. Pick a name for each job (anything you want)
# 2. Add names to JOBS list
# 3. Set the variables below using that name as prefix
#
# Two modes — pick one per job:
#
#   LOCAL mode  — move old snapshots to another disk on THIS host:
#     <name>_MODE="local"
#     <name>_SOURCE="/where/snapshots/are"
#     <name>_ARCHIVE="/where/to/archive"
#
#   REMOTE mode — send old snapshots to ANOTHER host via SSH:
#     <name>_MODE="remote"
#     <name>_SOURCE="/where/snapshots/are"
#     <name>_REMOTE_HOST="192.168.x.x"
#     <name>_REMOTE_USER="root"
#     <name>_REMOTE_PATH="/where/to/receive"
#
# ── Fill in your jobs below ──────────────────────────────────────────────────

JOBS=()
