#!/bin/bash
# =============================================
# Daily Incremental Btrfs Backup — REMOTE target
# Snapshot source → short-term dir → remote host via SSH
#
# Usage:
#   ./kvm-btrfs-backup-remote.sh              # run full backup
#   ./kvm-btrfs-backup-remote.sh --test-notify # only test Telegram
# =============================================

set -euo pipefail

# ─── CONFIGURATION (adjust per host) ────────────────────
BACKUP_NAME="win_b"               # label shown in Telegram messages
SOURCE="/work/kvm"                # btrfs subvolume to snapshot
SHORT_DIR="/work/backup"          # short-term snapshots (keep last N)
KEEP_SHORT=2                      # how many short-term snapshots to keep
LOG_FILE="/var/log/kvm-btrfs-backup.log"

# ─── REMOTE TARGET ─────────────────────────────────────
REMOTE_HOST="root@192.168.12.250" # user@ip of remote backup server
REMOTE_PATH="/backup/win_b/"      # path on remote server
SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no"

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
echo "Long-term  : ${REMOTE_HOST}:${REMOTE_PATH}"

send_telegram "🔄 <b>[${BACKUP_NAME}] Backup Started</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASource: <code>${SOURCE}</code>"

# Ensure short-term subvolume is writable
if btrfs property get "${SHORT_DIR}" ro 2>/dev/null | grep -q "true"; then
    echo "→ Making ${SHORT_DIR} writable"
    btrfs property set "${SHORT_DIR}" ro false
fi

echo "→ Creating snapshot: ${NEW_SNAP}"
btrfs subvolume snapshot -r "${SOURCE}" "${NEW_SNAP}"

RECEIVE_CMD="ssh ${SSH_OPTIONS} ${REMOTE_HOST} 'mkdir -p ${REMOTE_PATH} && btrfs receive ${REMOTE_PATH}'"

PREV_SNAP=$(ls -1d "${SHORT_DIR}"/20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | tail -n 2 | head -n 1 || true)

if [ -z "${PREV_SNAP}" ] || [ ! -d "${PREV_SNAP}" ]; then
    echo "→ First backup: sending FULL snapshot to ${REMOTE_HOST}:${REMOTE_PATH}"
    btrfs send "${NEW_SNAP}" | eval "${RECEIVE_CMD}"
else
    echo "→ Incremental send: parent=${PREV_SNAP} → new=${NEW_SNAP}"
    btrfs send -p "${PREV_SNAP}" "${NEW_SNAP}" | eval "${RECEIVE_CMD}"
fi

echo "→ Cleaning short-term (keeping last ${KEEP_SHORT})"
cd "${SHORT_DIR}"
mapfile -t OLD_SNAPS < <(ls -1d 20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | head -n -${KEEP_SHORT})
for old in "${OLD_SNAPS[@]}"; do
    echo "  Deleting old: ${old}"
    btrfs subvolume delete "${old}"
done

echo "=== [${BACKUP_NAME}] Btrfs Backup completed at $(date) ==="
send_telegram "✅ <b>[${BACKUP_NAME}] Backup Completed</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASnapshot: <code>${NEW_SNAP}</code>%0ALong-term: <code>${REMOTE_HOST}:${REMOTE_PATH}</code>"
