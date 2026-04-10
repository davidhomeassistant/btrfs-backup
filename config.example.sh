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
# Add your job names here, then define each one below.
#
# MODE "local"  → move old snapshots to another disk on THIS host
# MODE "remote" → send old snapshots to ANOTHER host via SSH
#
# For local  → set _SOURCE, _ARCHIVE
# For remote → set _SOURCE, _REMOTE_HOST, _REMOTE_USER, _REMOTE_PATH

JOBS=("")

# _MODE=""
# _SOURCE=""
# _ARCHIVE=""            # only for local
# _REMOTE_HOST=""        # only for remote
# _REMOTE_USER=""        # only for remote
# _REMOTE_PATH=""        # only for remote
