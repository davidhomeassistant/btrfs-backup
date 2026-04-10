#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/btrfs-backup"
SCRIPT="btrfs-backup-rotate.sh"
HOST="$(hostname)"
CONFIG_DIR="${INSTALL_DIR}/configs"
CONFIG_FILE="${CONFIG_DIR}/${HOST}.sh"
CRON_FILE="/etc/cron.d/btrfs-backup"
CRON_HOUR="${1:-3}"   # default 03:00, pass different hour as argument

echo "=== BTRFS Backup — install on ${HOST} ==="
echo ""

# check if config already exists
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config already exists: ${CONFIG_FILE}"
    echo "Skipping config creation (edit manually if needed)."
else
    echo "Creating config: ${CONFIG_FILE}"
    mkdir -p "$CONFIG_DIR"
    cp "${INSTALL_DIR}/config.example.sh" "$CONFIG_FILE"
    echo ""
    echo "*** IMPORTANT: edit ${CONFIG_FILE} now ***"
    echo "    Set HOSTNAME_ID, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID,"
    echo "    and define your JOBS with the correct paths for this host."
    echo ""
    read -rp "Open it in editor now? [Y/n] " yn
    case "${yn:-Y}" in
        [Nn]*) ;;
        *)     ${EDITOR:-vi} "$CONFIG_FILE" ;;
    esac
fi

# validate config has been edited
source "$CONFIG_FILE"
if [[ -z "${HOSTNAME_ID:-}" || "$HOSTNAME_ID" == "hypervisor1" ]]; then
    echo ""
    echo "WARNING: HOSTNAME_ID is still the default value."
    echo "Please edit ${CONFIG_FILE} before running the backup."
    echo ""
fi

# set up cron
echo "Setting up daily cron at ${CRON_HOUR}:00 ..."
cat > "$CRON_FILE" <<EOF
# BTRFS snapshot rotation — runs daily at ${CRON_HOUR}:00
0 ${CRON_HOUR} * * * root ${INSTALL_DIR}/${SCRIPT} -c ${CONFIG_FILE} >> /var/log/btrfs-backup-cron.log 2>&1
EOF
chmod 644 "$CRON_FILE"

echo ""
echo "Done. Summary:"
echo "  Script : ${INSTALL_DIR}/${SCRIPT}"
echo "  Config : ${CONFIG_FILE}"
echo "  Cron   : ${CRON_FILE} (daily at ${CRON_HOUR}:00)"
echo "  Log    : /var/log/btrfs-backup.log"
echo ""
echo "Test with dry-run first:"
echo "  ${INSTALL_DIR}/${SCRIPT} -c ${CONFIG_FILE} --dry-run --verbose"
