#!/bin/sh

print() { printf "%b%b" "${1-""}" "${2-"\\n"}"; }
stderr() { print "$@" 1>&2; }
reportError() { stderr "$2"; return "$1"; }
verbosePrint() { { test -n "${VERBOSE_MODE+x}" && stderr "$@"; } || true; }

commandv() { command -v "$1" || reportError "$?" "Executable '$1' not found"; }

KEEP_MINIMUM_BACKUPS="${KEEP_MINIMUM_BACKUPS:-"1"}"

btrfs_bin="$(commandv btrfs)"
btrfs() {
  BTRFS_SUB_VOL_INODE="256"

  _find_btrfs_volumes() {
    find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d -inum "$BTRFS_SUB_VOL_INODE" "$@"
    # log INFO find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d -inum "$BTRFS_SUB_VOL_INODE" "$@"
  }

  # Find nth latest backup
  _find_nth_latest() {
    _find_btrfs_volumes -exec stat --format "%Y %n" {} \; | sort -rn | awk -v LINE="$1" -v ORS='' 'BEGIN{if (LINE < 1) exit} NR==LINE {exit} END{$1=""; print substr($0, 2)}'
  }

  _find_extra_backups() {
    _KEEP_FROM="$(_find_nth_latest "$PRUNE_BACKUPS_COUNT")"
    if [ -n "$_KEEP_FROM" ]; then
      _find_btrfs_volumes -exec test "$_KEEP_FROM" -nt {} \; "$@"
    fi
  }

  _find_old_backups() {
    _KEEP_FROM="$(_find_nth_latest "$KEEP_MINIMUM_BACKUPS")"
    if [ -n "$_KEEP_FROM" ]; then
      _find_btrfs_volumes -mtime "+$PRUNE_BACKUPS_DAYS" -exec test "$_KEEP_FROM" -nt {} \; "$@"
    else
      _find_btrfs_volumes -mtime "+$PRUNE_BACKUPS_DAYS" "$@"
    fi
  }

  init() {
    # test DEST_DIR is btrfs volume
    test "btrfs" = "$(stat -f --format=%T "$SRC_DIR")" || reportError "1" "Filesystem not btrfs"
    test "$BTRFS_SUB_VOL_INODE" = "$(stat --format=%i "$SRC_DIR")" || reportError "1" "Source not a btrfs subvolume. (inode $(stat --format=%i "$SRC_DIR"))"

    if [ -d "$DEST_DIR" ]; then
      test "$BTRFS_SUB_VOL_INODE" = "$(stat --format=%i "$DEST_DIR")" || reportError "1" "Destination not a btrfs subvolume"
    else
      "$btrfs_bin" subvolume create "$DEST_DIR"
    fi
  }

  backup() {
    if [[ ! $1 ]]; then
      log INTERNALERROR "Backup log path not passed to btrfs.backup! Aborting"
      exit 1
    fi

    ts="$(date +"%Y-%m-%dT%H.%M.%S")"

    baseName="@${BACKUP_NAME}-${ts}"
    outFile="${DEST_DIR}/$baseName"
    log INFO "Backing up content in ${SRC_DIR} to ${outFile}"

    "$btrfs_bin" subvolume snapshot "$SRC_DIR" "$outFile"
    touch -m "$outFile" # Update modification time, as btrfs snapshot uses modification time of source
    "$btrfs_bin" property set -t subvol "$outFile" ro true # Set read-only to prevent accidental modifications to backup

    if [ "${LINK_LATEST^^}" == "TRUE" ]; then
      ln -snf "$baseName" "$DEST_DIR/@latest"
    fi
  }

  prune() {
    if [ -n "${PRUNE_BACKUPS_DAYS}" ] && [ "${PRUNE_BACKUPS_DAYS}" -gt 0 ]; then
      log INFO "Pruning backup files older than ${PRUNE_BACKUPS_DAYS} days"
      _find_old_backups -print -exec "$btrfs_bin" property set -t subvol {} ro false \; -exec "$btrfs_bin" subvolume delete {} \;
    fi

    if [ -n "${PRUNE_BACKUPS_COUNT}" ] && [ "${PRUNE_BACKUPS_COUNT}" -gt "$KEEP_MINIMUM_BACKUPS" ]; then
      log INFO "Pruning backup files to keep only the latest ${PRUNE_BACKUPS_COUNT} backups"
      _find_extra_backups -print -exec "$btrfs_bin" property set -t subvol {} ro false \; -exec "$btrfs_bin" subvolume delete {} \;
    fi
  }

  call_if_function_exists "${@}"
}
