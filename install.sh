#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/btrfs-backup"
SCRIPT="btrfs-backup-rotate.sh"
HOST="$(hostname)"
CONFIG_DIR="${INSTALL_DIR}/configs"
CONFIG_FILE="${CONFIG_DIR}/${HOST}.sh"
CRON_FILE="/etc/cron.d/btrfs-backup"
CRON_HOUR="${1:-3}"

echo ""
echo "=== BTRFS Backup — install on ${HOST} ==="
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config already exists: ${CONFIG_FILE}"
    echo "Delete it first if you want to reconfigure."
    echo ""
    echo "Test with dry-run:"
    echo "  ${INSTALL_DIR}/${SCRIPT} -c ${CONFIG_FILE} --dry-run --verbose"
    exit 0
fi

mkdir -p "$CONFIG_DIR"

# ── collect info ─────────────────────────────────────────────────────────────

read -rp "Hostname ID (shown in Telegram) [${HOST}]: " input_hostname
input_hostname="${input_hostname:-$HOST}"

read -rp "Telegram bot token (leave empty to skip): " input_token
read -rp "Telegram chat ID (leave empty to skip): " input_chatid

read -rp "How many snapshots to keep in source [2]: " input_keep
input_keep="${input_keep:-2}"

declare -a job_blocks=()
declare -a job_names=()

while true; do
    echo ""
    echo "── Add a backup job ──"
    read -rp "Job name (e.g. your VM or PC name): " jname
    [[ -z "$jname" ]] && { echo "Job name cannot be empty."; continue; }

    echo "  Mode:"
    echo "    1) local  — archive to another disk on THIS host"
    echo "    2) remote — send to ANOTHER host via SSH"
    read -rp "  Choose [1/2]: " jmode

    read -rp "  Source path (where snapshots are): " jsource

    block=""
    if [[ "$jmode" == "2" ]]; then
        read -rp "  Remote host IP: " jrhost
        read -rp "  Remote SSH user [root]: " jruser
        jruser="${jruser:-root}"
        read -rp "  Remote path: " jrpath
        block="${jname}_MODE=\"remote\"
${jname}_SOURCE=\"${jsource}\"
${jname}_REMOTE_HOST=\"${jrhost}\"
${jname}_REMOTE_USER=\"${jruser}\"
${jname}_REMOTE_PATH=\"${jrpath}\""
    else
        read -rp "  Archive path (local, different disk): " jarchive
        block="${jname}_MODE=\"local\"
${jname}_SOURCE=\"${jsource}\"
${jname}_ARCHIVE=\"${jarchive}\""
    fi

    job_names+=("$jname")
    job_blocks+=("$block")

    echo ""
    read -rp "Add another job? [y/N]: " more
    [[ "${more,,}" == "y" ]] || break
done

# ── write config ─────────────────────────────────────────────────────────────

jobs_list=$(printf '"%s" ' "${job_names[@]}")

cat > "$CONFIG_FILE" <<EOF
#!/usr/bin/env bash
HOSTNAME_ID="${input_hostname}"

TELEGRAM_BOT_TOKEN="${input_token}"
TELEGRAM_CHAT_ID="${input_chatid}"

KEEP_LOCAL=${input_keep}
KEEP_ARCHIVE=0

JOBS=(${jobs_list})

EOF

for block in "${job_blocks[@]}"; do
    echo "$block" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
done

echo ""
echo "Config written: ${CONFIG_FILE}"

# ── cron ─────────────────────────────────────────────────────────────────────

cat > "$CRON_FILE" <<EOF
# BTRFS snapshot rotation — daily at ${CRON_HOUR}:00
0 ${CRON_HOUR} * * * root ${INSTALL_DIR}/${SCRIPT} -c ${CONFIG_FILE} >> /var/log/btrfs-backup-cron.log 2>&1
EOF
chmod 644 "$CRON_FILE"

# ── done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Done:"
echo "  Config : ${CONFIG_FILE}"
echo "  Cron   : ${CRON_FILE} (daily at ${CRON_HOUR}:00)"
echo ""
echo "Running dry-run test now..."
echo ""

"${INSTALL_DIR}/${SCRIPT}" -c "${CONFIG_FILE}" --dry-run --verbose
