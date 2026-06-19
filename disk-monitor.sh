#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly CHECK_DIR='/'
readonly APP_LOG_DIR='/var/log/app'
readonly ARCHIVE_DIR="${APP_LOG_DIR}/archive"
readonly LOG_FILE='/var/log/disk-monitor.log'
readonly PID_FILE='/run/disk-monitor.pid'
readonly ROLLBACK_STATE='/run/disk-monitor.rollback'
readonly SLEEP_INTERVAL=300
readonly USAGE_THRESHOLD=80
readonly ALERT_THRESHOLD=90

DRY_RUN='false'
MODE='one-time'
RUNNING='true'

log() {
  local message="${1:-}"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "$timestamp" "$message" | sudo tee -a "$LOG_FILE" >/dev/null
}

error() {
  local message="${1:-}"
  printf '%s\n' "$message" >&2
  log "ERROR: $message"
}

usage() {
  cat <<EOF >&2
Usage: $SCRIPT_NAME [--daemon|--one-time] [--dry-run] [--rollback]
  --daemon     Run continuously every 5 minutes
  --one-time   Run once and exit (default)
  --dry-run    Show actions without performing them
  --rollback   Decompress and restore moved files from archive
EOF
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --daemon)
        MODE='daemon'
        shift
        ;;
      --one-time)
        MODE='one-time'
        shift
        ;;
      --dry-run)
        DRY_RUN='true'
        shift
        ;;
      --rollback)
        MODE='rollback'
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        usage
        ;;
    esac
  done
}

ensure_single_instance() {
  if sudo test -f "$PID_FILE"; then
    local existing_pid
    existing_pid="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      log "Monitor already running with PID $existing_pid"
      printf 'Monitor already running with PID %s\n' "$existing_pid" >&2
      exit 0
    fi
    sudo rm -f "$PID_FILE"
  fi

  if [ "$DRY_RUN" = 'true' ]; then
    printf '%s\n' "$$" | sudo tee "$PID_FILE" >/dev/null
  else
    printf '%s\n' "$$" | sudo tee "$PID_FILE" >/dev/null
  fi
}

cleanup() {
  if sudo test -f "$PID_FILE"; then
    sudo rm -f "$PID_FILE"
  fi
}

current_usage() {
  df -P "$CHECK_DIR" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }'
}

find_old_log_files() {
  find "$APP_LOG_DIR" -maxdepth 1 -type f -mtime +7 ! -name '*.gz' -print0
}

calculate_required_space_kb() {
  local total_kb=0
  while IFS= read -r -d '' file; do
    local size
    size=$(sudo stat -c '%s' "$file")
    total_kb=$((total_kb + (size + 1023) / 1024))
  done < <(find_old_log_files)
  printf '%s' "$total_kb"
}

verify_archive_directory() {
  if [ "$DRY_RUN" = 'true' ]; then
    log "[DRY-RUN] Would ensure archive directory exists: $ARCHIVE_DIR"
    return 0
  fi

  sudo mkdir -p "$ARCHIVE_DIR"
}

verify_archive_space() {
  local required_kb
  required_kb="$1"
  local available_kb
  available_kb=$(df --output=avail -k "$APP_LOG_DIR" | tail -n1 | tr -d '[:space:]')
  if [ -z "$available_kb" ]; then
    error "Unable to determine available space for $ARCHIVE_DIR"
    return 1
  fi

  if [ "$available_kb" -lt "$required_kb" ]; then
    error "Insufficient available space in $ARCHIVE_DIR: required ${required_kb}KB, available ${available_kb}KB"
    return 1
  fi

  log "Archive directory has sufficient space: ${available_kb}KB available, ${required_kb}KB required"
}

record_rollback_entry() {
  local archive_file="$1"
  local original_file="$2"
  printf '%s\0%s\0' "$archive_file" "$original_file" | sudo tee -a "$ROLLBACK_STATE" >/dev/null
}

compress_and_move_logs() {
  local files_found=0
  local moved_count=0
  local summary_buffer=''

  while IFS= read -r -d '' file; do
    files_found=1
    local base_name
    base_name="$(basename "$file")"
    local archive_path="$ARCHIVE_DIR/$base_name"

    if [ "$DRY_RUN" = 'true' ]; then
      log "[DRY-RUN] Would move and compress '$file' to '$archive_path.gz'"
      continue
    fi

    log "Moving '$file' to archive and compressing"
    sudo mv "$file" "$ARCHIVE_DIR/"
    sudo gzip "$archive_path"
    record_rollback_entry "$archive_path.gz" "$file"
    moved_count=$((moved_count + 1))
    summary_buffer+="Compressed and moved: $archive_path.gz\n"
  done < <(find_old_log_files)

  if [ "$files_found" -eq 0 ]; then
    log "No log files older than 7 days found in $APP_LOG_DIR"
    return 0
  fi

  if [ "$DRY_RUN" = 'false' ] && [ "$moved_count" -gt 0 ]; then
    log "Compressed and moved $moved_count files to $ARCHIVE_DIR"
    printf '%s' "$summary_buffer" | while IFS= read -r line; do
      log "$line"
    done
  fi
}

rollback() {
  if [ "$DRY_RUN" = 'true' ]; then
    log '[DRY-RUN] Would restore moved files from archive'
    echo '[DRY-RUN] rollback mode enabled: no changes made'
    exit 0
  fi

  if ! sudo test -f "$ROLLBACK_STATE"; then
    log "No rollback state file found at $ROLLBACK_STATE"
    echo "No rollback state available"
    exit 0
  fi

  log "Restoring moved files from archive"
  sudo bash -c "
    while IFS= read -r -d '' archive_file && IFS= read -r -d '' original_file; do
      if [ -z \"$archive_file\" ] || [ -z \"$original_file\" ]; then
        continue
      fi
      if [ ! -f \"$archive_file\" ]; then
        echo \"Rollback warning: archive file missing: $archive_file\"
        continue
      fi
      mkdir -p \"\$(dirname \"$original_file\")\"
      gzip -dc \"$archive_file\" | tee \"$original_file\" >/dev/null
      echo \"Restored $original_file from $archive_file\"
    done < \"$ROLLBACK_STATE\"
  "

  log "Rollback completed"
  sudo rm -f "$ROLLBACK_STATE"
  cleanup
  exit 0
}

monitor_cycle() {
  local usage
  usage=$(current_usage)
  log "Disk usage on $CHECK_DIR is ${usage}%"

  if [ "$usage" -ge "$ALERT_THRESHOLD" ]; then
    local alert_msg="ALERT: / usage is ${usage}% which exceeds ${ALERT_THRESHOLD}%"
    printf '%s\n' "$alert_msg" >&2
    log "$alert_msg"
  fi

  if [ "$usage" -lt "$USAGE_THRESHOLD" ]; then
    log "Disk usage below threshold (${usage}% < ${USAGE_THRESHOLD}%)"
    return
  fi

  local required_kb
  required_kb=$(calculate_required_space_kb)
  if [ "$required_kb" -eq 0 ]; then
    log "No eligible old log files to compress"
    return
  fi

  verify_archive_directory
  verify_archive_space "$required_kb"
  compress_and_move_logs
}

main() {
  parse_args "$@"

  if [ "$MODE" = 'rollback' ]; then
    rollback
  fi

  ensure_single_instance
  trap cleanup EXIT
  trap rollback INT TERM

  log "Starting disk monitor in mode=$MODE dry-run=$DRY_RUN"

  if [ "$MODE" = 'daemon' ]; then
    while [ "$RUNNING" = 'true' ]; do
      monitor_cycle
      sleep "$SLEEP_INTERVAL"
    done
  else
    monitor_cycle
  fi
}

main "$@"
