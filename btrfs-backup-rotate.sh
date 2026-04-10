#!/usr/bin/env bash
#
# btrfs-backup-rotate.sh — BTRFS snapshot rotation & backup
#
# LOCAL mode:  archive old snapshots to another disk, then delete from source
# REMOTE mode: ensure kept snapshots are on remote host, then delete old from source
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.0.0"
readonly LOCK_DIR="/var/run"
readonly DEFAULT_LOG="/var/log/btrfs-backup.log"
readonly SNAP_RE='^[0-9]{4}_[0-9]{2}_[0-9]{2}$'

HOSTNAME_ID=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
KEEP_LOCAL=2
KEEP_ARCHIVE=0
LOG_FILE="$DEFAULT_LOG"
declare -a JOBS=()

DRY_RUN=false
VERBOSE=false
CONFIG_FILE=""
LOCK_FILE=""
ONLY_JOBS=()
declare -a ERRORS=()
declare -a SUMMARY=()

###############################################################################
# CLI
###############################################################################

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -c CONFIG [OPTIONS]

  -c, --config FILE   Config file (required)
  -n, --dry-run       Show what would happen, change nothing
  -v, --verbose       More output
  -j, --job NAME      Run only this job
  -h, --help          Help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -j|--job)     ONLY_JOBS+=("$2"); shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            --version)    echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            *)            echo "Unknown: $1" >&2; usage; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { echo "Error: -c CONFIG required" >&2; exit 1; }
    [[ -f "$CONFIG_FILE" ]] || { echo "Error: $CONFIG_FILE not found" >&2; exit 1; }
}

###############################################################################
# Logging
###############################################################################

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "[$(_ts)] [INFO]  $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo "[$(_ts)] [WARN]  $*" | tee -a "$LOG_FILE" >&2; }
log_error() { echo "[$(_ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; ERRORS+=("$*"); }
log_debug() { $VERBOSE && echo "[$(_ts)] [DEBUG] $*" | tee -a "$LOG_FILE" || true; }
die()       { log_error "$*"; notify "FAILED"; release_lock; exit 1; }

###############################################################################
# Lock
###############################################################################

acquire_lock() {
    LOCK_FILE="${LOCK_DIR}/btrfs-backup-${HOSTNAME_ID}.lock"
    if [[ -f "$LOCK_FILE" ]]; then
        local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Already running (PID $pid)"
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap release_lock EXIT
}
release_lock() { [[ -n "${LOCK_FILE:-}" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"; }

###############################################################################
# Telegram
###############################################################################

notify() {
    local status="$1"
    local icon="❌"; [[ "$status" == "OK" ]] && icon="✅"
    local msg="${icon} <b>[${HOSTNAME_ID}]</b> ${status}"
    if [[ ${#SUMMARY[@]} -gt 0 ]]; then
        msg+=$'\n'
        for s in "${SUMMARY[@]}"; do msg+=$'\n'"• ${s}"; done
    fi
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        msg+=$'\n\n'"<b>Errors:</b>"
        for e in "${ERRORS[@]}"; do msg+=$'\n'"⚠️ ${e}"; done
    fi
    $DRY_RUN && msg+=$'\n\n'"<i>(dry-run)</i>"

    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    if $DRY_RUN; then log_info "[DRY-RUN] Telegram message prepared"; return 0; fi
    curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 \
    || log_warn "Telegram send failed"
}

###############################################################################
# Snapshot helpers
###############################################################################

get_snapshots() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    for d in "$dir"/*/; do
        [[ -d "$d" ]] || continue
        local name; name="$(basename "$d")"
        [[ "$name" =~ $SNAP_RE ]] && echo "$name"
    done | sort
}

in_list() {
    local needle="$1"; shift
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# Find best parent: most recent snapshot older than $current that exists
# in both source and target.
find_parent() {
    local src="$1" current="$2"; shift 2
    local -a target=("$@")
    local -a srcs; mapfile -t srcs < <(get_snapshots "$src")
    local best=""
    for s in "${srcs[@]}"; do
        [[ "$s" < "$current" ]] || continue
        in_list "$s" "${target[@]}" && best="$s"
    done
    echo "$best"
}

###############################################################################
# btrfs send/receive
###############################################################################

send_local() {
    local src="$1" snap="$2" dst="$3" parent="${4:-}"
    if $DRY_RUN; then
        [[ -n "$parent" ]] \
            && log_info "[DRY-RUN] btrfs send -p ${src}/${parent} ${src}/${snap} | btrfs receive ${dst}/" \
            || log_info "[DRY-RUN] btrfs send ${src}/${snap} | btrfs receive ${dst}/"
        return 0
    fi
    mkdir -p "$dst"
    local cmd
    [[ -n "$parent" ]] \
        && { log_info "Send ${snap} (parent ${parent}) → ${dst}/"; cmd="btrfs send -p '${src}/${parent}' '${src}/${snap}' | btrfs receive '${dst}/'"; } \
        || { log_info "Full send ${snap} → ${dst}/"; cmd="btrfs send '${src}/${snap}' | btrfs receive '${dst}/'"; }
    if ! eval "$cmd" 2>>"$LOG_FILE"; then
        log_error "Send failed: ${snap} → ${dst}"
        [[ -d "${dst}/${snap}" ]] && { btrfs subvolume delete "${dst}/${snap}" 2>/dev/null || true; }
        return 1
    fi
    [[ -d "${dst}/${snap}" ]] || { log_error "Verify failed: ${dst}/${snap}"; return 1; }
    log_info "OK: ${snap} → ${dst}"
}

send_remote() {
    local src="$1" snap="$2" host="$3" rpath="$4" parent="${5:-}"
    if $DRY_RUN; then
        [[ -n "$parent" ]] \
            && log_info "[DRY-RUN] btrfs send -p ${src}/${parent} ${src}/${snap} | ssh ${host} btrfs receive ${rpath}/" \
            || log_info "[DRY-RUN] btrfs send ${src}/${snap} | ssh ${host} btrfs receive ${rpath}/"
        return 0
    fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "mkdir -p '${rpath}'" 2>>"$LOG_FILE" \
        || { log_error "Cannot mkdir ${rpath} on ${host}"; return 1; }
    local cmd
    [[ -n "$parent" ]] \
        && { log_info "Send ${snap} (parent ${parent}) → ${host}:${rpath}/"; cmd="btrfs send -p '${src}/${parent}' '${src}/${snap}' | ssh -o ConnectTimeout=10 -o BatchMode=yes '${host}' 'btrfs receive \"${rpath}/\"'"; } \
        || { log_info "Full send ${snap} → ${host}:${rpath}/"; cmd="btrfs send '${src}/${snap}' | ssh -o ConnectTimeout=10 -o BatchMode=yes '${host}' 'btrfs receive \"${rpath}/\"'"; }
    if ! eval "$cmd" 2>>"$LOG_FILE"; then
        log_error "Send failed: ${snap} → ${host}:${rpath}"
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
            "btrfs subvolume delete '${rpath}/${snap}' 2>/dev/null || true" 2>/dev/null || true
        return 1
    fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "test -d '${rpath}/${snap}'" 2>/dev/null \
        || { log_error "Verify failed: ${host}:${rpath}/${snap}"; return 1; }
    log_info "OK: ${snap} → ${host}"
}

delete_snap() {
    local path="$1" snap="$2"
    if $DRY_RUN; then log_info "[DRY-RUN] btrfs subvolume delete ${path}/${snap}"; return 0; fi
    log_info "Delete ${path}/${snap}"
    btrfs subvolume delete "${path}/${snap}" 2>>"$LOG_FILE" \
        || { log_error "Delete failed: ${path}/${snap}"; return 1; }
}

###############################################################################
# LOCAL mode: archive old snapshots to another disk, then delete from source
###############################################################################

do_local() {
    local job="$1" src="$2"
    local -n _snaps=$3
    local av="${job}_ARCHIVE"; local archive="${!av%/}"
    log_info "  archive: ${archive}"

    local total=${#_snaps[@]}
    if [[ $total -le $KEEP_LOCAL ]]; then
        SUMMARY+=("${job}: ${total} snap(s), nothing to do")
        return 0
    fi

    local split=$((total - KEEP_LOCAL))
    local -a old=("${_snaps[@]:0:$split}")
    local -a keep=("${_snaps[@]:$split}")
    log_info "  archive: ${old[*]}"
    log_info "  keep   : ${keep[*]}"

    local -a arch_list=()
    mapfile -t arch_list < <(get_snapshots "$archive")

    local ok=0 fail=0
    for snap in "${old[@]}"; do
        if in_list "$snap" "${arch_list[@]}" 2>/dev/null; then
            log_info "  ${snap} already archived"
            ((ok++)) || true
        else
            local p; p=$(find_parent "$src" "$snap" "${arch_list[@]}")
            if send_local "$src" "$snap" "$archive" "$p"; then
                arch_list+=("$snap"); ((ok++)) || true
            else
                ((fail++)) || true; continue
            fi
        fi
        # delete from source right after successful archive
        if $DRY_RUN || [[ -d "${archive}/${snap}" ]]; then
            delete_snap "$src" "$snap"
        else
            log_warn "Skip delete ${snap}: not in archive"
        fi
    done

    [[ -d "$archive" && "${KEEP_ARCHIVE:-0}" -gt 0 ]] && {
        local -a al; mapfile -t al < <(get_snapshots "$archive")
        local c=${#al[@]}
        if [[ $c -gt $KEEP_ARCHIVE ]]; then
            local rm=$((c - KEEP_ARCHIVE))
            log_info "  Trimming archive: remove ${rm} oldest"
            for ((i=0; i<rm; i++)); do delete_snap "$archive" "${al[$i]}"; done
        fi
    }

    local line="${job}: archived=${ok} kept=${#keep[@]}"
    [[ $fail -gt 0 ]] && line+=" errors=${fail}"
    SUMMARY+=("$line")
}

###############################################################################
# REMOTE mode: ensure kept snapshots are on remote, then delete old from source
#
# Logic:
#   1. Split into old (to delete) and keep (newest N)
#   2. Make sure every "keep" snapshot exists on remote
#   3. If a keep snapshot fails to send → STOP, don't delete anything
#   4. Delete old snapshots from source
###############################################################################

do_remote() {
    local job="$1" src="$2"
    local -n _snaps=$3
    local hv="${job}_REMOTE_HOST"; local rhost="${!hv}"
    local uv="${job}_REMOTE_USER"; local ruser="${!uv}"
    local pv="${job}_REMOTE_PATH"; local rpath="${!pv%/}"
    local ssh_target="${ruser}@${rhost}"
    log_info "  remote: ${ssh_target}:${rpath}"

    local total=${#_snaps[@]}
    if [[ $total -le $KEEP_LOCAL ]]; then
        SUMMARY+=("${job}: ${total} snap(s), nothing to do")
        return 0
    fi

    local split=$((total - KEEP_LOCAL))
    local -a old=("${_snaps[@]:0:$split}")
    local -a keep=("${_snaps[@]:$split}")
    log_info "  remove : ${old[*]}"
    log_info "  keep   : ${keep[*]}"

    # test SSH
    if ! $DRY_RUN; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$ssh_target" "echo ok" >/dev/null 2>&1 \
            || { log_error "SSH failed: ${ssh_target}"; SUMMARY+=("${job}: FAILED (SSH)"); return 1; }
    fi

    # get what's already on remote
    local -a on_remote=()
    if ! $DRY_RUN; then
        mapfile -t on_remote < <(
            ssh -o ConnectTimeout=10 -o BatchMode=yes "$ssh_target" \
                "ls -1 '${rpath}/' 2>/dev/null" | grep -E "$SNAP_RE" | sort
        ) || true
    fi

    # step 1: make sure kept snapshots are on remote
    local sent=0
    for snap in "${keep[@]}"; do
        if in_list "$snap" "${on_remote[@]}" 2>/dev/null; then
            log_debug "  ${snap} already on remote"
            continue
        fi
        local p; p=$(find_parent "$src" "$snap" "${on_remote[@]}")
        if send_remote "$src" "$snap" "$ssh_target" "$rpath" "$p"; then
            on_remote+=("$snap"); ((sent++)) || true
        else
            log_error "Cannot confirm ${snap} on remote — aborting delete to protect data"
            SUMMARY+=("${job}: ABORTED — could not send ${snap} to remote")
            return 1
        fi
    done

    # step 2: delete old snapshots from source (safe — kept ones are on remote)
    local deleted=0
    for snap in "${old[@]}"; do
        delete_snap "$src" "$snap" && ((deleted++)) || true
    done

    SUMMARY+=("${job}: sent=${sent} deleted=${deleted} kept=${#keep[@]} → ${ssh_target}")
}

###############################################################################
# Config
###############################################################################

load_config() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    [[ -z "${HOSTNAME_ID:-}" ]]    && die "HOSTNAME_ID not set"
    [[ -z "${JOBS[*]:-}" ]]        && die "No JOBS defined"
    [[ "${KEEP_LOCAL:-0}" -lt 1 ]] && die "KEEP_LOCAL must be >= 1"
    for job in "${JOBS[@]}"; do
        local sv="${job}_SOURCE"; [[ -z "${!sv:-}" ]] && die "${sv} not set"
        local mv="${job}_MODE";  local mode="${!mv:-}"
        [[ "$mode" != "local" && "$mode" != "remote" ]] && die "${mv} must be 'local' or 'remote'"
        if [[ "$mode" == "local" ]]; then
            local av="${job}_ARCHIVE"; [[ -z "${!av:-}" ]] && die "${av} required"
        else
            for v in REMOTE_HOST REMOTE_USER REMOTE_PATH; do
                local vn="${job}_${v}"; [[ -z "${!vn:-}" ]] && die "${vn} required"
            done
        fi
    done
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG}"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/btrfs-backup.log"
    log_info "Config: host=${HOSTNAME_ID} jobs=(${JOBS[*]}) keep=${KEEP_LOCAL}"
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"
    load_config
    acquire_lock

    log_info "════════════════════════════════════════"
    log_info " btrfs-backup-rotate v${SCRIPT_VERSION}"
    log_info " Host: ${HOSTNAME_ID}"
    $DRY_RUN && log_info " *** DRY-RUN ***"
    log_info "════════════════════════════════════════"

    local errs=0
    for job in "${JOBS[@]}"; do
        if [[ ${#ONLY_JOBS[@]} -gt 0 ]]; then
            local ok=false
            for oj in "${ONLY_JOBS[@]}"; do [[ "$oj" == "$job" ]] && ok=true; done
            $ok || continue
        fi

        local sv="${job}_SOURCE"; local src="${!sv%/}"
        local mv="${job}_MODE";  local mode="${!mv}"
        log_info "━━━ ${job} (${mode}) ━━━"
        log_info "  source: ${src}"

        if [[ ! -d "$src" ]]; then
            log_error "Source missing: ${src}"
            SUMMARY+=("${job}: SKIPPED")
            ((errs++)) || true; continue
        fi

        local -a snaps; mapfile -t snaps < <(get_snapshots "$src")
        log_info "  found: ${#snaps[@]} snapshot(s)"

        if [[ "$mode" == "local" ]]; then
            do_local "$job" "$src" snaps || ((errs++)) || true
        else
            do_remote "$job" "$src" snaps || ((errs++)) || true
        fi
    done

    if [[ $errs -gt 0 || ${#ERRORS[@]} -gt 0 ]]; then
        notify "FAILED"; exit 1
    fi
    notify "OK"
    log_info "Done"
}

main "$@"
