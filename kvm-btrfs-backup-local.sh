#!/bin/bash
# =============================================
# Daily Incremental Btrfs Backup — LOCAL target
# Snapshot source → short-term dir → local long-term dir
#
# Usage:
#   ./kvm-btrfs-backup-local.sh              # run full backup
#   ./kvm-btrfs-backup-local.sh --test-notify # only test Telegram
# =============================================

set -euo pipefail

# ─── CONFIGURATION (adjust per host) ────────────────────
BACKUP_NAME="faeton"              # label shown in Telegram messages
SOURCE="/work/virt/windows"       # btrfs subvolume to snapshot
SHORT_DIR="/work/backup"          # short-term snapshots (keep last N)
LONG_DIR="/backup/kvm"            # local long-term destination
KEEP_SHORT=2                      # how many short-term snapshots to keep
LOG_FILE="/var/log/kvm-btrfs-backup.log"

# ─── TELEGRAM (same for all hosts) ─────────────────────
TG_BOT_TOKEN="8628713377:AAF7KnlTxVAQMIog_FF3kVZhb5_dJg98wEg"
TG_CHAT_ID="-5203867313"
# ────────────────────────────────────────────────────────

DATE=$(date +%Y_%m_%d)
HOSTNAME=$(hostname)
NEW_SNAP="${SHORT_DIR}/${DATE}"

send_telegram() {
    local message="$1"
    wget -qO- --post-data="chat_id=${TG_CHAT_ID}&parse_mode=HTML&text=${message}" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" > /dev/null 2>&1 || true
}

if [[ "${1:-}" == "--test-notify" ]]; then
    echo "Sending test notification to Telegram..."
    send_telegram "🔔 <b>[${BACKUP_NAME}] Test Notification</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0A%0ATelegram notifications are working!"
    echo "Done. Check your Telegram group."
    exit 0
fi

on_error() {
    local exit_code=$?
    send_telegram "❌ <b>[${BACKUP_NAME}] Backup FAILED</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0AExit code: <code>${exit_code}</code>%0ACheck: <code>${LOG_FILE}</code>"
    exit "$exit_code"
}
trap on_error ERR

echo "=== [${BACKUP_NAME}] Btrfs Backup started at $(date) ==="
echo "Source     : ${SOURCE}"
echo "Short-term : ${SHORT_DIR} (keep last ${KEEP_SHORT})"
echo "Long-term  : ${LONG_DIR}"

send_telegram "🔄 <b>[${BACKUP_NAME}] Backup Started</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASource: <code>${SOURCE}</code>"

mkdir -p "${SHORT_DIR}"
echo "→ Creating snapshot: ${NEW_SNAP}"
btrfs subvolume snapshot -r "${SOURCE}" "${NEW_SNAP}"

PREV_SNAP=$(ls -1d "${SHORT_DIR}"/20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | tail -n 2 | head -n 1 || true)

mkdir -p "${LONG_DIR}"

if [ -z "${PREV_SNAP}" ] || [ ! -d "${PREV_SNAP}" ]; then
    echo "→ First backup: sending FULL snapshot to ${LONG_DIR}"
    btrfs send "${NEW_SNAP}" | btrfs receive "${LONG_DIR}"
else
    echo "→ Incremental send: parent=${PREV_SNAP} → new=${NEW_SNAP}"
    btrfs send -p "${PREV_SNAP}" "${NEW_SNAP}" | btrfs receive "${LONG_DIR}"
fi

echo "→ Cleaning short-term (keeping last ${KEEP_SHORT})"
cd "${SHORT_DIR}"
mapfile -t OLD_SNAPS < <(ls -1d 20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | head -n -${KEEP_SHORT})
for old in "${OLD_SNAPS[@]}"; do
    echo "  Deleting old: ${old}"
    btrfs subvolume delete "${old}"
done

echo "=== [${BACKUP_NAME}] Btrfs Backup completed at $(date) ==="
send_telegram "✅ <b>[${BACKUP_NAME}] Backup Completed</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASnapshot: <code>${NEW_SNAP}</code>%0ALong-term: <code>${LONG_DIR}</code>"
