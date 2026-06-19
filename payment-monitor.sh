#!/usr/bin/env bash
set -euo pipefail

readonly LOG_FILE="/var/log/payment-monitor.log"
readonly PID_FILE="/run/payment-monitor.pid"
readonly HEALTH_URL="http://localhost:80"
readonly SLEEP_INTERVAL="30"
readonly SERVICE_NAME="apache2"
readonly SCRIPT_NAME="$(basename "$0")"

DRY_RUN="false"
RUNNING="true"
ORIGINAL_SERVICE_ACTIVE=""

log() {
  local message="${1:-}"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "$timestamp" "$message" | sudo tee -a "$LOG_FILE" >/dev/null
}

capture_thread_dump() {
  log "Capturing apache thread dump"
  local thread_snapshot
  thread_snapshot="$(ps -eLf 2>/dev/null | grep '[a]pache2' || true)"
  if [ -n "$thread_snapshot" ]; then
    printf '%s\n' "$thread_snapshot" | while IFS= read -r line; do
      log "THREAD: $line"
    done
  else
    log "No apache2 thread information available"
  fi
  local status_snapshot
  status_snapshot="$(sudo systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true)"
  if [ -n "$status_snapshot" ]; then
    printf '%s\n' "$status_snapshot" | while IFS= read -r line; do
      log "STATUS: $line"
    done
  fi
}

restart_apache() {
  log "Health endpoint is unhealthy, preparing to restart apache"
  capture_thread_dump
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would restart $SERVICE_NAME"
    return 0
  fi
  log "Restarting $SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
  log "Restart of $SERVICE_NAME completed"
}

health_check() {
  local status_code
  status_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>/dev/null || true)"

  if [ "$status_code" != "200" ]; then
    log "Health check failed: response code '$status_code'"
    restart_apache
  else
    log "Health check OK: 200"
  fi
}

rollback() {
  local current_state="${ORIGINAL_SERVICE_ACTIVE:-}"

  log "Rollback requested: stopping monitor loop"
  RUNNING="false"

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] Would restore original service state '$current_state'"
  elif [ "$current_state" = "active" ]; then
    log "Restoring original service state: starting $SERVICE_NAME"
    sudo systemctl start "$SERVICE_NAME" || log "Failed to restore $SERVICE_NAME to active"
  elif [ -n "$current_state" ]; then
    log "Restoring original service state: stopping $SERVICE_NAME"
    sudo systemctl stop "$SERVICE_NAME" || log "Failed to restore $SERVICE_NAME to inactive"
  else
    log "Original service state unknown; skipping restore"
  fi

  rm -f "$PID_FILE"
  log "Rollback complete"
  exit 0
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      --dry-run)
        DRY_RUN="true"
        ;;
      *)
        printf 'Usage: %s [--dry-run]\n' "$SCRIPT_NAME" >&2
        exit 1
        ;;
    esac
  fi
}

ensure_single_instance() {
  if [ -f "$PID_FILE" ]; then
    local existing_pid
    existing_pid="$(<"$PID_FILE")"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      log "Monitor is already running with PID $existing_pid"
      printf 'Monitor already running with PID %s\n' "$existing_pid" >&2
      exit 0
    fi
    rm -f "$PID_FILE"
  fi

  if ! printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null; then
    sudo bash -c "printf '%s\n' '$$' > '$PID_FILE'"
  fi
}

set_original_service_state() {
  ORIGINAL_SERVICE_ACTIVE="$(sudo systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  log "Original $SERVICE_NAME state is '$ORIGINAL_SERVICE_ACTIVE'"
}

main() {
  parse_args "$@"
  ensure_single_instance
  set_original_service_state

  trap rollback INT TERM EXIT

  log "Starting payment monitor (dry-run=$DRY_RUN)"
  while [ "$RUNNING" = "true" ]; do
    health_check
    sleep "$SLEEP_INTERVAL"
  done
}

main "$@"
