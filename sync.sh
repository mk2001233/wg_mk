#!/usr/bin/env bash
#
# sync.sh — Sync this repo to a remote host via rsync (with scp+tar fallback).
#
# Usage:
#   bash sync.sh <remote_host> <remote_dir> [extra_excludes...]
#
# Examples:
#   bash sync.sh root@123.57.216.161 /opt/wg-easy/scripts
#   bash sync.sh root@10.8.0.2 /opt/wg-easy/scripts data logs
#
# How it works:
#   1. If the remote has rsync, uses rsync -avz --delete (fast, incremental, deletes stale files).
#   2. Otherwise falls back to scp+tar (no remote-only file cleanup).
#   3. macOS tar metadata (._* resource forks, xattrs) is stripped automatically.
#
# Default excludes:
#   .git  tmp  *.log  *.tmp  .*.tmp.*  *.swp  *.swo  .DS_Store  sync.sh
#
# Extra excludes passed as trailing arguments are appended to the default list.

set -Eeuo pipefail

LOG_PREFIX="[wg-sync]"

log() { echo "$LOG_PREFIX $*" >&2; }

if [[ $# -lt 2 ]]; then
  log "Usage: bash sync.sh <remote_host> <remote_dir> [extra_excludes...]"
  exit 1
fi

REMOTE_HOST="$1"
REMOTE_DIR="$2"
shift 2

log "Syncing ./ -> $REMOTE_HOST:$REMOTE_DIR"

LOCAL_TMP_DIR="./tmp"

EXCLUDE_PATTERNS=(
  ".git"
  "tmp"
  "*.log"
  "*.tmp"
  ".*.tmp.*"
  "*.swp"
  "*.swo"
  ".DS_Store"
  "sync.sh"
)
for item in "$@"; do
  EXCLUDE_PATTERNS+=("$item")
done

EXCLUDES=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDES+=("--exclude=$pattern")
done

shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

create_temp_dir() {
  mkdir -p "$LOCAL_TMP_DIR"
  printf '%s\n' "$LOCAL_TMP_DIR"
}

create_local_archive() {
  local archive="$1"
  shift

  if [[ "$(uname -s)" == "Darwin" ]]; then
    env COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
      tar --no-mac-metadata --no-xattrs -czf "$archive" "$@"
    return
  fi

  tar -czf "$archive" "$@"
}

remote_has_command() {
  local command_name="$1"
  local status=0

  ssh "$REMOTE_HOST" "command -v $command_name >/dev/null 2>&1" || status=$?

  if [[ $status -eq 0 ]]; then
    return 0
  fi
  if [[ $status -eq 1 ]]; then
    return 1
  fi

  log "Failed to check whether $command_name is available on $REMOTE_HOST."
  exit "$status"
}

sync_with_rsync() {
  log "Creating remote directory $REMOTE_DIR"
  ssh "$REMOTE_HOST" "mkdir -p $(shell_quote "$REMOTE_DIR")"
  log "Starting rsync"
  rsync -avz --delete \
    -e "ssh" \
    "${EXCLUDES[@]}" \
    ./ "$REMOTE_HOST:$REMOTE_DIR"
  log "Rsync complete"
}

sync_with_scp_fallback() {
  local tmp_dir=""
  local archive=""
  local remote_archive=""
  local quoted_remote_dir=""
  local quoted_remote_archive=""
  local tar_excludes=()

  if ! remote_has_command tar; then
    log "Remote tar is required for the scp fallback on $REMOTE_HOST."
    exit 1
  fi

  tmp_dir="$(create_temp_dir)"
  archive="$tmp_dir/wg_mk_sync_${USER:-user}_$$.tar.gz"
  remote_archive="/tmp/wg_mk_sync_${USER:-user}_$$.tar.gz"
  quoted_remote_dir="$(shell_quote "$REMOTE_DIR")"
  quoted_remote_archive="$(shell_quote "$remote_archive")"
  tar_excludes=("${EXCLUDES[@]}" "--exclude=$archive" "--exclude=${archive#./}")

  trap "rm -f -- $(printf '%q' "$archive")" EXIT

  log "Remote rsync is unavailable on $REMOTE_HOST; using scp fallback."
  log "The scp fallback preserves the exclude list, but it does not delete remote-only files."

  log "Creating local archive"
  create_local_archive "$archive" "${tar_excludes[@]}" .
  log "Uploading archive to $REMOTE_HOST"
  scp "$archive" "$REMOTE_HOST:$remote_archive"
  log "Extracting archive on $REMOTE_HOST:$REMOTE_DIR"
  ssh "$REMOTE_HOST" "status=0; mkdir -p $quoted_remote_dir && tar -xzf $quoted_remote_archive -C $quoted_remote_dir || status=\$?; rm -f $quoted_remote_archive; exit \$status"

  rm -f "$archive"
  trap - EXIT
  log "Scp fallback complete"
}

log "Checking remote for rsync"
if remote_has_command rsync; then
  sync_with_rsync
else
  sync_with_scp_fallback
fi
