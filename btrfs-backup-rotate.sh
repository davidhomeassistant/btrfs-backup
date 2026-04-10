#!/usr/bin/env bash
#
# btrfs-backup-rotate.sh — BTRFS snapshot rotation, archival & remote replication
#
# Keeps N most recent snapshots locally, archives older ones to a separate
# BTRFS volume, optionally replicates to remote hosts via SSH, and sends
# Telegram notifications on success or failure.
#
# SAFETY: supports --dry-run, lock files, verification after every send,
#         and never deletes a source snapshot unless the archive copy is confirmed.
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly LOCK_DIR="/var/run"
readonly DEFAULT_LOG="/var/log/btrfs-backup.log"
readonly SNAP_RE='^[0-9]{4}_[0-9]{2}_[0-9]{2}$'

# --- globals set by config ---
HOSTNAME_ID=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
KEEP_LOCAL=2
KEEP_ARCHIVE=0          # 0 = unlimited
LOG_FILE="$DEFAULT_LOG"
declare -a JOBS=()

# --- runtime state ---
DRY_RUN=false
VERBOSE=false
CONFIG_FILE=""
LOCK_FILE=""
declare -a ERRORS=()
declare -a WARNINGS=()
declare -a SUMMARY=()

###############################################################################
# CLI
###############################################################################

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -c CONFIG [OPTIONS]

Options:
  -c, --config FILE   Configuration file (required)
  -n, --dry-run       Show what would happen without touching anything
  -v, --verbose       Debug-level output
  -j, --job NAME      Run only the named job (may be repeated)
  -h, --help          This message
  --version           Print version
EOF
}

ONLY_JOBS=()

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -j|--job)     ONLY_JOBS+=("$2"); shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            --version)    echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { echo "Error: -c CONFIG is required" >&2; usage; exit 1; }
    [[ -f "$CONFIG_FILE" ]] || { echo "Error: config not found: $CONFIG_FILE" >&2; exit 1; }
}

###############################################################################
# Logging
###############################################################################

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { local m="[$(_ts)] [INFO]  $*"; echo "$m" | tee -a "$LOG_FILE"; }
log_warn()  { local m="[$(_ts)] [WARN]  $*"; echo "$m" | tee -a "$LOG_FILE" >&2; WARNINGS+=("$*"); }
log_error() { local m="[$(_ts)] [ERROR] $*"; echo "$m" | tee -a "$LOG_FILE" >&2; ERRORS+=("$*"); }
log_debug() { $VERBOSE && { local m="[$(_ts)] [DEBUG] $*"; echo "$m" | tee -a "$LOG_FILE"; } || true; }

die() { log_error "$*"; send_notification "FAILED"; release_lock; exit 1; }

###############################################################################
# Lock
###############################################################################

acquire_lock() {
    LOCK_FILE="${LOCK_DIR}/btrfs-backup-${HOSTNAME_ID}.lock"
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Another instance running (PID $pid). Lock: $LOCK_FILE"
        fi
        log_warn "Removing stale lock (was PID $pid)"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap release_lock EXIT
}

release_lock() {
    [[ -n "${LOCK_FILE:-}" && -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
}

###############################################################################
# Telegram
###############################################################################

send_telegram() {
    local text="$1"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    if $DRY_RUN; then
        log_info "[DRY-RUN] Telegram → ${text:0:120}…"
        return 0
    fi
    curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 \
    || log_warn "Telegram delivery failed"
}

send_notification() {
    local status="$1"
    local icon="❌"
    [[ "$status" == "OK" ]] && icon="✅"

    local msg="${icon} <b>[${HOSTNAME_ID}]</b> Backup rotation: <b>${status}</b>"

    if [[ ${#SUMMARY[@]} -gt 0 ]]; then
        msg+=$'\n'
        for s in "${SUMMARY[@]}"; do msg+=$'\n'"• ${s}"; done
    fi
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        msg+=$'\n\n'"<b>Errors:</b>"
        for e in "${ERRORS[@]}"; do msg+=$'\n'"⚠️ ${e}"; done
    fi
    $DRY_RUN && msg+=$'\n\n'"<i>(dry-run, no changes made)</i>"

    send_telegram "$msg"
}

###############################################################################
# Snapshot helpers
###############################################################################

# Print snapshot directory names matching YYYY_MM_DD, sorted ascending.
get_snapshots() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    local name
    for d in "$dir"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ "$name" =~ $SNAP_RE ]] && echo "$name"
    done | sort
}

snap_exists_local() { [[ -d "$1/$2" ]]; }

snap_exists_remote() {
    local host="$1" path="$2" name="$3"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
        "test -d '${path}/${name}'" 2>/dev/null
}

# Given an array of snapshot names present at the target and the source path,
# return the most recent common parent older than $current.
find_parent() {
    local source_path="$1" current="$2"
    shift 2
    local -a target_list=("$@")

    local -a src_snaps
    mapfile -t src_snaps < <(get_snapshots "$source_path")

    local best=""
    for s in "${src_snaps[@]}"; do
        [[ "$s" < "$current" ]] || continue
        for t in "${target_list[@]}"; do
            [[ "$s" == "$t" ]] && { best="$s"; break; }
        done
    done
    echo "$best"
}

###############################################################################
# Send operations
###############################################################################

btrfs_send_local() {
    local src="$1" snap="$2" dst="$3" parent="${4:-}"
    local full="${src}/${snap}"

    if $DRY_RUN; then
        if [[ -n "$parent" ]]; then
            log_info "[DRY-RUN] btrfs send -p ${src}/${parent} ${full} | btrfs receive ${dst}/"
        else
            log_info "[DRY-RUN] btrfs send ${full} | btrfs receive ${dst}/"
        fi
        return 0
    fi

    mkdir -p "$dst"

    local cmd
    if [[ -n "$parent" ]]; then
        log_info "Incremental send ${snap} (parent ${parent}) → ${dst}/"
        cmd="btrfs send -p '${src}/${parent}' '${full}' | btrfs receive '${dst}/'"
    else
        log_info "Full send ${snap} → ${dst}/"
        cmd="btrfs send '${full}' | btrfs receive '${dst}/'"
    fi

    if ! eval "$cmd" 2>>"$LOG_FILE"; then
        log_error "btrfs send failed: ${snap} → ${dst}"
        [[ -d "${dst}/${snap}" ]] && \
            { btrfs subvolume delete "${dst}/${snap}" 2>/dev/null || rm -rf "${dst}/${snap}" 2>/dev/null || true; }
        return 1
    fi

    snap_exists_local "$dst" "$snap" || { log_error "Verification failed: ${dst}/${snap} missing after send"; return 1; }
    log_info "Archived ${snap} ✓"
}

btrfs_send_remote() {
    local src="$1" snap="$2" host="$3" rpath="$4" parent="${5:-}"
    local full="${src}/${snap}"

    if $DRY_RUN; then
        if [[ -n "$parent" ]]; then
            log_info "[DRY-RUN] btrfs send -p ${src}/${parent} ${full} | ssh ${host} btrfs receive ${rpath}/"
        else
            log_info "[DRY-RUN] btrfs send ${full} | ssh ${host} btrfs receive ${rpath}/"
        fi
        return 0
    fi

    ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "mkdir -p '${rpath}'" 2>>"$LOG_FILE" \
        || { log_error "Cannot create ${rpath} on ${host}"; return 1; }

    local cmd
    if [[ -n "$parent" ]]; then
        log_info "Incremental send ${snap} (parent ${parent}) → ${host}:${rpath}/"
        cmd="btrfs send -p '${src}/${parent}' '${full}' | ssh -o ConnectTimeout=10 -o BatchMode=yes '${host}' 'btrfs receive \"${rpath}/\"'"
    else
        log_info "Full send ${snap} → ${host}:${rpath}/"
        cmd="btrfs send '${full}' | ssh -o ConnectTimeout=10 -o BatchMode=yes '${host}' 'btrfs receive \"${rpath}/\"'"
    fi

    if ! eval "$cmd" 2>>"$LOG_FILE"; then
        log_error "Remote send failed: ${snap} → ${host}:${rpath}"
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
            "btrfs subvolume delete '${rpath}/${snap}' 2>/dev/null || true" 2>/dev/null || true
        return 1
    fi

    snap_exists_remote "$host" "$rpath" "$snap" \
        || { log_error "Verification failed: ${host}:${rpath}/${snap} missing after send"; return 1; }
    log_info "Remote-sent ${snap} → ${host} ✓"
}

delete_snapshot() {
    local path="$1" snap="$2"
    if $DRY_RUN; then
        log_info "[DRY-RUN] btrfs subvolume delete ${path}/${snap}"
        return 0
    fi
    log_info "Deleting ${path}/${snap}"
    btrfs subvolume delete "${path}/${snap}" 2>>"$LOG_FILE" \
        || { log_error "Delete failed: ${path}/${snap}"; return 1; }
}

###############################################################################
# Archive retention
###############################################################################

trim_archive() {
    local apath="$1" keep="$2"
    [[ "$keep" -le 0 ]] && return 0
    local -a snaps
    mapfile -t snaps < <(get_snapshots "$apath")
    local total=${#snaps[@]}
    [[ $total -le $keep ]] && return 0
    local to_rm=$((total - keep))
    log_info "Archive retention: removing ${to_rm} oldest from ${apath}"
    for ((i = 0; i < to_rm; i++)); do
        delete_snapshot "$apath" "${snaps[$i]}"
    done
}

###############################################################################
# Job processing
###############################################################################

process_job() {
    local job_name="$1"

    # read per-job variables via indirect expansion
    local src_var="${job_name}_SOURCE"  ; local source_path="${!src_var}"
    local arch_var="${job_name}_ARCHIVE"; local archive_path="${!arch_var}"
    local rem_var="${job_name}_REMOTE"  ; local remote_spec="${!rem_var:-}"

    log_info "━━━ Job: ${job_name} ━━━"
    log_info "  source : ${source_path}"
    log_info "  archive: ${archive_path}"
    [[ -n "$remote_spec" ]] && log_info "  remote : ${remote_spec}"

    if [[ ! -d "$source_path" ]]; then
        log_error "Source path missing: ${source_path}"
        SUMMARY+=("${job_name}: SKIPPED (source missing)")
        return 1
    fi

    # ── collect snapshots ────────────────────────────────────────────────
    local -a src_snaps
    mapfile -t src_snaps < <(get_snapshots "$source_path")
    local total=${#src_snaps[@]}
    log_info "  snapshots in source: ${total}"

    if [[ $total -le $KEEP_LOCAL ]]; then
        log_info "  nothing to rotate (have ${total}, keep ${KEEP_LOCAL})"
        SUMMARY+=("${job_name}: ${total} snapshot(s), nothing to rotate")
        # still do remote if configured
        [[ -n "$remote_spec" ]] && _do_remote "$source_path" "$remote_spec" src_snaps "$job_name"
        return 0
    fi

    local keep_from=$((total - KEEP_LOCAL))
    local -a to_archive=("${src_snaps[@]:0:$keep_from}")
    local -a to_keep=("${src_snaps[@]:$keep_from}")

    log_info "  to archive: ${to_archive[*]}"
    log_info "  to keep   : ${to_keep[*]}"

    # ── phase 1: archive ─────────────────────────────────────────────────
    local -a arch_snaps=()
    if [[ -n "$archive_path" ]]; then
        mapfile -t arch_snaps < <(get_snapshots "$archive_path")
    fi

    local archived=0 arch_err=0
    for snap in "${to_archive[@]}"; do
        if printf '%s\n' "${arch_snaps[@]}" 2>/dev/null | grep -qx "$snap"; then
            log_info "  ${snap} already in archive"
            ((archived++)) || true
            continue
        fi
        local parent
        parent=$(find_parent "$source_path" "$snap" "${arch_snaps[@]}")
        if btrfs_send_local "$source_path" "$snap" "$archive_path" "$parent"; then
            arch_snaps+=("$snap")
            ((archived++)) || true
        else
            ((arch_err++)) || true
        fi
    done

    # ── phase 2: remote ──────────────────────────────────────────────────
    [[ -n "$remote_spec" ]] && _do_remote "$source_path" "$remote_spec" src_snaps "$job_name"

    # ── phase 3: delete archived from source ─────────────────────────────
    local deleted=0
    for snap in "${to_archive[@]}"; do
        if [[ -n "$archive_path" ]]; then
            snap_exists_local "$archive_path" "$snap" 2>/dev/null \
                || { $DRY_RUN || { log_warn "Skip delete ${snap}: not confirmed in archive"; continue; }; }
        fi
        delete_snapshot "$source_path" "$snap" && ((deleted++)) || true
    done

    # ── phase 4: archive retention ───────────────────────────────────────
    [[ -n "$archive_path" && -d "$archive_path" ]] && trim_archive "$archive_path" "${KEEP_ARCHIVE:-0}"

    local line="${job_name}: archived=${archived} deleted=${deleted} kept=${#to_keep[@]}"
    [[ $arch_err -gt 0 ]] && line+=" errors=${arch_err}"
    SUMMARY+=("$line")
    log_info "  ${line}"
}

_do_remote() {
    local source_path="$1" remote_spec="$2"
    local -n _snaps=$3
    local job_name="$4"

    local host="${remote_spec%%:*}"
    local rpath="${remote_spec#*:}"
    [[ -z "$host" || -z "$rpath" ]] && { log_error "Bad remote spec: ${remote_spec}"; return 1; }

    log_info "  ── remote replication → ${host}:${rpath} ──"

    if ! $DRY_RUN; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "echo ok" >/dev/null 2>&1 \
            || { log_error "SSH unreachable: ${host}"; SUMMARY+=("${job_name}: remote FAILED (SSH)"); return 1; }
    fi

    # fetch remote snapshot list once
    local -a rsnaps=()
    if ! $DRY_RUN; then
        mapfile -t rsnaps < <(
            ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" \
                "ls -1 '${rpath}/' 2>/dev/null" | grep -E "$SNAP_RE" | sort
        ) || true
    fi

    local sent=0 rerr=0
    for snap in "${_snaps[@]}"; do
        if printf '%s\n' "${rsnaps[@]}" 2>/dev/null | grep -qx "$snap"; then
            log_debug "  ${snap} already on remote"
            continue
        fi
        local parent
        parent=$(find_parent "$source_path" "$snap" "${rsnaps[@]}")
        if btrfs_send_remote "$source_path" "$snap" "$host" "$rpath" "$parent"; then
            rsnaps+=("$snap")
            ((sent++)) || true
        else
            ((rerr++)) || true
        fi
    done

    local line="${job_name}: remote_sent=${sent} → ${host}"
    [[ $rerr -gt 0 ]] && line+=" remote_errors=${rerr}"
    SUMMARY+=("$line")
}

###############################################################################
# Config
###############################################################################

load_config() {
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    [[ -z "${HOSTNAME_ID:-}" ]]    && die "HOSTNAME_ID not set in config"
    [[ -z "${JOBS[*]:-}" ]]        && die "No JOBS defined in config"
    [[ "${KEEP_LOCAL:-0}" -lt 1 ]] && die "KEEP_LOCAL must be >= 1"

    # validate that each job has at least a _SOURCE defined
    for job in "${JOBS[@]}"; do
        local src_var="${job}_SOURCE"
        [[ -z "${!src_var:-}" ]] && die "Job '${job}': ${src_var} is not set in config"
        local arch_var="${job}_ARCHIVE"
        [[ -z "${!arch_var:-}" ]] && die "Job '${job}': ${arch_var} is not set in config"
    done

    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG}"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/btrfs-backup.log"

    log_info "Config loaded: host=${HOSTNAME_ID} jobs=${#JOBS[@]} (${JOBS[*]}) keep_local=${KEEP_LOCAL}"
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"
    load_config
    acquire_lock

    log_info "══════════════════════════════════════════"
    log_info " BTRFS Backup Rotation v${SCRIPT_VERSION}"
    log_info " Host: ${HOSTNAME_ID}"
    $DRY_RUN && log_info " *** DRY-RUN — nothing will be changed ***"
    log_info "══════════════════════════════════════════"

    local job_errors=0

    for job_name in "${JOBS[@]}"; do
        # if --job filters given, skip non-matching
        if [[ ${#ONLY_JOBS[@]} -gt 0 ]]; then
            local match=false
            for oj in "${ONLY_JOBS[@]}"; do [[ "$oj" == "$job_name" ]] && match=true; done
            $match || continue
        fi

        process_job "$job_name" || ((job_errors++)) || true
    done

    if [[ $job_errors -gt 0 || ${#ERRORS[@]} -gt 0 ]]; then
        send_notification "FAILED"
        log_error "Finished with errors"
        exit 1
    fi

    send_notification "OK"
    log_info "All jobs completed successfully"
}

main "$@"
