#!/bin/bash
# Daily incremental Btrfs backup for KVM VM
# Short-term: /work/backup → keep only last 2
# Long-term:  /backup/kvm  → keep ALL (incremental send)
#
# Usage:
#   ./kvm-btrfs-backup.sh              # run full backup
#   ./kvm-btrfs-backup.sh --test-notify # only test Telegram notification

set -euo pipefail

# --- Telegram config ---
TG_BOT_TOKEN="8628713377:AAF7KnlTxVAQMIog_FF3kVZhb5_dJg98wEg"
TG_CHAT_ID="-5203867313"

DATE=$(date +%Y_%m_%d)
HOSTNAME=$(hostname)
SOURCE="/work/virt/windows"
SHORT_DIR="/work/backup"
LONG_DIR="/backup/kvm"
NEW_SNAP="${SHORT_DIR}/${DATE}"

send_telegram() {
    local message="$1"
    wget -qO- --post-data="chat_id=${TG_CHAT_ID}&parse_mode=HTML&text=${message}" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" > /dev/null 2>&1 || true
}

# --- Test notification mode ---
if [[ "${1:-}" == "--test-notify" ]]; then
    echo "Sending test notification to Telegram..."
    send_telegram "🔔 <b>Test Notification</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0A%0ATelegram notifications are working!"
    echo "Done. Check your Telegram group."
    exit 0
fi

on_error() {
    local exit_code=$?
    send_telegram "❌ <b>KVM Backup FAILED</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0AExit code: <code>${exit_code}</code>%0ACheck: <code>/var/log/kvm-btrfs-backup.log</code>"
    exit "$exit_code"
}
trap on_error ERR

echo "=== KVM Btrfs Backup started at $(date) ==="
send_telegram "🔄 <b>KVM Backup Started</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASource: <code>${SOURCE}</code>"

# 1. Create new read-only snapshot
mkdir -p "${SHORT_DIR}"
echo "→ Creating new snapshot: ${NEW_SNAP}"
btrfs subvolume snapshot -r "${SOURCE}" "${NEW_SNAP}"

# 2. Find previous snapshot in SHORT_DIR for incremental send
PREV_SNAP=$(ls -1d "${SHORT_DIR}"/20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | tail -n 2 | head -n 1 || true)

mkdir -p "${LONG_DIR}"

if [ -z "${PREV_SNAP}" ] || [ ! -d "${PREV_SNAP}" ]; then
    echo "→ First backup: sending FULL snapshot to ${LONG_DIR}"
    btrfs send "${NEW_SNAP}" | btrfs receive "${LONG_DIR}"
else
    echo "→ Incremental send: parent = ${PREV_SNAP} → new = ${NEW_SNAP}"
    btrfs send -p "${PREV_SNAP}" "${NEW_SNAP}" | btrfs receive "${LONG_DIR}"
fi

# 3. Cleanup short-term: keep only the last 2 snapshots
echo "→ Cleaning short-term (keeping last 2)"
cd "${SHORT_DIR}"
mapfile -t OLD_SNAPS < <(ls -1d 20[0-9][0-9]_[0-9][0-9]_[0-9][0-9] 2>/dev/null | sort | head -n -2)
for old in "${OLD_SNAPS[@]}"; do
    echo "  Deleting old short-term snapshot: ${old}"
    btrfs subvolume delete "${old}"
done

echo "=== KVM Btrfs Backup completed successfully at $(date) ==="
send_telegram "✅ <b>KVM Backup Completed</b>%0A%0AHost: <code>${HOSTNAME}</code>%0ADate: <code>${DATE}</code>%0ASnapshot: <code>${NEW_SNAP}</code>%0ALong-term: <code>${LONG_DIR}</code>"
