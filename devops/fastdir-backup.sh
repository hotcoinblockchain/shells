#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOCK_FILE="/run/lock/fastdir-backup.lock"

ACTION=""
SOURCE=""
OUTPUT=""
ARCHIVE=""
DEST=""
THREADS="0"
LEVEL="3"
ONE_FILE_SYSTEM=false
MERGE=false
SKIP_SPACE_CHECK=false
STAGING_DIR=""
EXCLUDES=()

TX_DIR=""
TMP_ARCHIVE=""
TMP_CHECKSUM=""
RESTORE_STAGE=""
ROLLBACK_DIR=""
DEST_CREATED=false
RESTORE_STARTED=false
COMMITTED=false

log() {
  local level=$1
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >&2
}

fatal() {
  log ERROR "$*"
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} backup  --source DIR --output FILE.tar.zst [options]
  ${SCRIPT_NAME} restore --archive FILE.tar.zst --dest DIR [--merge] [options]
  ${SCRIPT_NAME} verify  --archive FILE.tar.zst

Backup options:
  --source DIR              Directory whose CONTENTS will be archived.
  --output FILE             Output .tar.zst archive path.
  --threads N               zstd worker threads; 0 = all CPU cores (default: 0).
  --level N                 zstd compression level 1..19 (default: 3).
  --exclude PATTERN         tar exclude pattern; repeatable.
  --one-file-system         Do not cross filesystem boundaries below source.
  --skip-space-check        Skip conservative free-space precheck.

Restore options:
  --archive FILE            Archive created by this script.
  --dest DIR                Restore archive CONTENTS into this directory.
  --merge                   Allow restoring into a non-empty destination.
                            Existing replaced files are backed up during this run.
  --staging-dir DIR         Temporary extraction parent; default: parent of --dest.
  --skip-space-check        Skip conservative staging free-space precheck.

Examples:
  ${SCRIPT_NAME} backup --source /root --output /backup/root-$(date +%F).tar.zst --threads 0
  ${SCRIPT_NAME} restore --archive /backup/root-2026-08-12.tar.zst --dest /root --merge
  ${SCRIPT_NAME} verify --archive /backup/root-2026-08-12.tar.zst

Notes:
  * If --source is /root, the archive contains the contents of /root, not a top-level root/ folder.
  * Restore to an existing non-empty directory requires --merge intentionally.
  * Source or destination '/' is rejected as a safety guard.
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "Run as root so ownership, ACLs and xattrs can be preserved"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

is_gnu_tar() {
  tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar'
}

canonical_existing_dir() {
  local p=$1
  [[ -n $p ]] || fatal "Directory path cannot be empty"
  [[ $p == /* ]] || fatal "Directory path must be absolute: $p"
  [[ -d $p ]] || fatal "Directory does not exist: $p"
  [[ ! -L $p ]] || fatal "Refusing symlink directory path: $p"
  realpath -e -- "$p"
}

canonical_future_path() {
  local p=$1 parent base
  [[ -n $p ]] || fatal "Path cannot be empty"
  [[ $p == /* ]] || fatal "Path must be absolute: $p"
  parent=$(dirname -- "$p")
  base=$(basename -- "$p")
  [[ $base != "." && $base != ".." ]] || fatal "Unsafe path: $p"
  [[ -d $parent ]] || fatal "Parent directory does not exist: $parent"
  [[ ! -L $parent ]] || fatal "Refusing symlink parent directory: $parent"
  parent=$(realpath -e -- "$parent")
  printf '%s/%s\n' "$parent" "$base"
}

reject_dangerous_dir() {
  local p=$1 label=$2
  [[ $p != "/" ]] || fatal "Refusing ${label} '/'. Choose a specific directory such as /root"
}

path_is_inside() {
  local child=$1 parent=$2
  [[ $child == "$parent" || $child == "$parent"/* ]]
}

acquire_lock() {
  mkdir -p -- "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || fatal "Another ${SCRIPT_NAME} process is already running"
}

cleanup() {
  local rc=$?

  if (( rc != 0 )) && [[ $COMMITTED != true ]]; then
    if [[ $RESTORE_STARTED == true && -n $ROLLBACK_DIR && -d $ROLLBACK_DIR && -n $DEST && -d $DEST ]]; then
      log WARN "Restore failed; attempting to put replaced pre-existing files back"
      rsync -aHAXS --numeric-ids -- "$ROLLBACK_DIR/" "$DEST/" || log ERROR "Best-effort rollback encountered an error"
      log WARN "Files newly created before the failure may remain in the destination"
    fi
    if [[ $DEST_CREATED == true && -n $DEST && -d $DEST ]]; then
      log WARN "Removing destination created by this failed invocation: $DEST"
      rm -rf --one-file-system -- "$DEST" || true
    fi
  fi

  [[ -n $TMP_ARCHIVE && -f $TMP_ARCHIVE ]] && rm -f -- "$TMP_ARCHIVE"
  [[ -n $TMP_CHECKSUM && -f $TMP_CHECKSUM ]] && rm -f -- "$TMP_CHECKSUM"
  [[ -n $RESTORE_STAGE && -d $RESTORE_STAGE ]] && rm -rf --one-file-system -- "$RESTORE_STAGE"
  [[ -n $TX_DIR && -d $TX_DIR ]] && rm -rf --one-file-system -- "$TX_DIR"

  return "$rc"
}

on_error() {
  local rc=$1 line=$2
  log ERROR "Command failed at line ${line} with exit code ${rc}"
  exit "$rc"
}

on_signal() {
  local sig=$1
  log WARN "Received signal ${sig}"
  exit 128
}

check_common_dependencies() {
  local command_name

  for command_name in awk basename chmod date df dirname du find grep mkdir mktemp mv \
    realpath rm sha256sum tar zstd; do
    require_command "$command_name"
  done
  is_gnu_tar || fatal "GNU tar is required"
}

check_tar_features() {
  local help
  help=$(tar --help)
  grep -q -- '--acls' <<<"$help" || fatal "GNU tar lacks ACL support (--acls)"
  grep -q -- '--xattrs' <<<"$help" || fatal "GNU tar lacks xattr support (--xattrs)"
  grep -q -- '--sparse' <<<"$help" || fatal "GNU tar lacks sparse-file support (--sparse)"
}

free_bytes_for_path() {
  df -PB1 -- "$1" | awk 'NR==2 {print $4}'
}

source_bytes() {
  du -sxB1 -- "$1" | awk '{print $1}'
}

archive_uncompressed_bytes() {
  zstd -lv -- "$1" 2>/dev/null | awk '
    /^Decompressed Size:/ {
      value=$0
      sub(/^Decompressed Size:[[:space:]]*/, "", value)
      sub(/[[:space:]].*$/, "", value)
      gsub(/,/, "", value)
      if (value ~ /^[0-9]+$/) {
        print value
        found=1
      }
    }
    END {if (!found) exit 1}
  '
}

check_backup_space() {
  [[ $SKIP_SPACE_CHECK == true ]] && return 0
  local need free outdir
  need=$(source_bytes "$SOURCE")
  outdir=$(dirname -- "$OUTPUT")
  free=$(free_bytes_for_path "$outdir")
  log INFO "Conservative space check: source=${need} bytes, free=${free} bytes"
  (( free > need + need / 20 + 67108864 )) || fatal "Not enough free space for a conservative backup estimate; use --skip-space-check only if you accept the risk"
}

check_restore_space() {
  [[ $SKIP_SPACE_CHECK == true ]] && return 0
  local need free parent
  parent=$STAGING_DIR
  if ! need=$(archive_uncompressed_bytes "$ARCHIVE"); then
    log WARN "Could not read decompressed size from zstd frame; skipping staging size estimate"
    return 0
  fi
  free=$(free_bytes_for_path "$parent")
  log INFO "Staging space check: estimated_uncompressed=${need} bytes, free=${free} bytes"
  (( free > need + need / 20 + 67108864 )) || fatal "Not enough free space for safe staged restore; choose --staging-dir on a larger filesystem or use --skip-space-check"
}

validate_checksum() {
  local sidecar expected actual
  sidecar="${ARCHIVE}.sha256"
  [[ -f $sidecar ]] || fatal "Checksum sidecar not found: $sidecar"
  [[ ! -L $sidecar ]] || fatal "Refusing symlink checksum sidecar: $sidecar"
  expected=$(awk 'NR==1 {print $1}' "$sidecar")
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || fatal "Invalid checksum file: $sidecar"
  actual=$(sha256sum -- "$ARCHIVE" | awk '{print $1}')
  [[ ${actual,,} == ${expected,,} ]] || fatal "SHA-256 mismatch for archive"
  log INFO "SHA-256 verified"
}

validate_archive() {
  log INFO "Testing zstd frame"
  zstd -q -t -- "$ARCHIVE"
  validate_checksum

  log INFO "Checking archive member paths"
  if ! zstd -q -d -c -- "$ARCHIVE" | tar -tf - | awk '
    BEGIN { bad=0 }
    {
      name=$0
      if (name ~ /^\//) {
        print "unsafe absolute archive path: " name > "/dev/stderr"
        bad=1
      }
      n=split(name, a, "/")
      for (i=1; i<=n; i++) {
        if (a[i] == "..") {
          print "unsafe parent traversal in archive path: " name > "/dev/stderr"
          bad=1
        }
      }
    }
    END { exit bad }
  '; then
    fatal "Archive path validation failed"
  fi
  log INFO "Archive structure validated"
}

backup_action() {
  SOURCE=$(canonical_existing_dir "$SOURCE")
  reject_dangerous_dir "$SOURCE" "source"
  OUTPUT=$(canonical_future_path "$OUTPUT")

  path_is_inside "$OUTPUT" "$SOURCE" && fatal "Output archive must not be inside the source directory"
  [[ ! -e $OUTPUT ]] || fatal "Output already exists: $OUTPUT"
  [[ ! -e ${OUTPUT}.sha256 ]] || fatal "Checksum sidecar already exists: ${OUTPUT}.sha256"
  [[ $THREADS =~ ^[0-9]+$ ]] || fatal "--threads must be a non-negative integer"
  [[ $LEVEL =~ ^[0-9]+$ ]] && (( LEVEL >= 1 && LEVEL <= 19 )) || fatal "--level must be an integer from 1 to 19"

  check_backup_space

  local outdir outfile hash
  outdir=$(dirname -- "$OUTPUT")
  outfile=$(basename -- "$OUTPUT")
  TMP_ARCHIVE=$(mktemp "${outdir}/.${outfile}.partial.XXXXXX")
  TMP_CHECKSUM=$(mktemp "${outdir}/.${outfile}.sha256.partial.XXXXXX")

  local -a tar_args=(
    --create
    --file=-
    --directory="$SOURCE"
    --acls
    --xattrs
    --xattrs-include='*'
    --numeric-owner
    --sparse
  )
  [[ $ONE_FILE_SYSTEM == true ]] && tar_args+=(--one-file-system)
  local pattern
  for pattern in "${EXCLUDES[@]}"; do
    tar_args+=(--exclude="$pattern")
  done
  tar_args+=(.)

  log INFO "Backing up $SOURCE -> $OUTPUT using zstd threads=$THREADS level=$LEVEL"
  tar "${tar_args[@]}" | zstd -q -T"$THREADS" "-${LEVEL}" -c > "$TMP_ARCHIVE"

  zstd -q -t -- "$TMP_ARCHIVE"
  hash=$(sha256sum -- "$TMP_ARCHIVE" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$outfile" > "$TMP_CHECKSUM"
  chmod 0600 -- "$TMP_ARCHIVE" "$TMP_CHECKSUM"

  mv -- "$TMP_ARCHIVE" "$OUTPUT"
  TMP_ARCHIVE=""
  mv -- "$TMP_CHECKSUM" "${OUTPUT}.sha256"
  TMP_CHECKSUM=""
  COMMITTED=true

  log INFO "Backup complete"
  log INFO "Archive: $OUTPUT"
  log INFO "Checksum: ${OUTPUT}.sha256"
}

restore_action() {
  require_command rsync

  ARCHIVE=$(realpath -e -- "$ARCHIVE")
  [[ -f $ARCHIVE ]] || fatal "Archive is not a regular file: $ARCHIVE"

  if [[ -e $DEST ]]; then
    DEST=$(canonical_existing_dir "$DEST")
  else
    DEST=$(canonical_future_path "$DEST")
  fi
  reject_dangerous_dir "$DEST" "destination"

  if [[ -z $STAGING_DIR ]]; then
    STAGING_DIR=$(dirname -- "$DEST")
  fi
  STAGING_DIR=$(canonical_existing_dir "$STAGING_DIR")
  path_is_inside "$STAGING_DIR" "$DEST" && \
    fatal "Staging directory must not be the destination or inside it: $STAGING_DIR"

  validate_archive
  check_restore_space

  if [[ -d $DEST ]] && find "$DEST" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    [[ $MERGE == true ]] || fatal "Destination is not empty. Re-run with --merge to allow overwriting matching paths"
  fi

  RESTORE_STAGE=$(mktemp -d "${STAGING_DIR}/.fastdir-restore.XXXXXX")
  mkdir -p -- "$RESTORE_STAGE/data" "$RESTORE_STAGE/rollback"
  ROLLBACK_DIR="$RESTORE_STAGE/rollback"

  log INFO "Extracting archive into staging directory"
  zstd -q -d -c -- "$ARCHIVE" | tar \
    --extract \
    --file=- \
    --directory="$RESTORE_STAGE/data" \
    --preserve-permissions \
    --same-owner \
    --numeric-owner \
    --acls \
    --xattrs \
    --xattrs-include='*' \
    --sparse

  if [[ ! -d $DEST ]]; then
    mkdir -p -- "$DEST"
    DEST_CREATED=true
  fi

  local -a rsync_args=(
    -aHAXS
    --numeric-ids
    --human-readable
    --info=stats2,progress2
  )

  if [[ $MERGE == true ]]; then
    rsync_args+=(--backup --backup-dir="$ROLLBACK_DIR")
  fi

  RESTORE_STARTED=true
  log INFO "Synchronizing staged data into $DEST"
  rsync "${rsync_args[@]}" -- "$RESTORE_STAGE/data/" "$DEST/"

  COMMITTED=true
  RESTORE_STARTED=false
  log INFO "Restore complete: $DEST"
  if [[ $MERGE == true ]]; then
    log INFO "Existing files replaced during this run were protected until the restore succeeded"
  fi
}

verify_action() {
  ARCHIVE=$(realpath -e -- "$ARCHIVE")
  [[ -f $ARCHIVE ]] || fatal "Archive is not a regular file: $ARCHIVE"
  validate_archive
  COMMITTED=true
  log INFO "Archive verification passed: $ARCHIVE"
}

parse_args() {
  (($# >= 1)) || { usage; exit 2; }
  ACTION=$1
  shift

  case "$ACTION" in
    backup|restore|verify) ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "Unknown subcommand: $ACTION" ;;
  esac

  while (($#)); do
    case "$1" in
      --source)
        (($# >= 2)) || fatal "--source requires a value"
        SOURCE=$2
        shift 2
        ;;
      --output)
        (($# >= 2)) || fatal "--output requires a value"
        OUTPUT=$2
        shift 2
        ;;
      --archive)
        (($# >= 2)) || fatal "--archive requires a value"
        ARCHIVE=$2
        shift 2
        ;;
      --dest)
        (($# >= 2)) || fatal "--dest requires a value"
        DEST=$2
        shift 2
        ;;
      --threads)
        (($# >= 2)) || fatal "--threads requires a value"
        THREADS=$2
        shift 2
        ;;
      --level)
        (($# >= 2)) || fatal "--level requires a value"
        LEVEL=$2
        shift 2
        ;;
      --exclude)
        (($# >= 2)) || fatal "--exclude requires a value"
        EXCLUDES+=("$2")
        shift 2
        ;;
      --one-file-system)
        ONE_FILE_SYSTEM=true
        shift
        ;;
      --merge)
        MERGE=true
        shift
        ;;
      --staging-dir)
        (($# >= 2)) || fatal "--staging-dir requires a value"
        STAGING_DIR=$2
        shift 2
        ;;
      --skip-space-check)
        SKIP_SPACE_CHECK=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown argument: $1"
        ;;
    esac
  done

  case "$ACTION" in
    backup)
      [[ -n $SOURCE ]] || fatal "backup requires --source DIR"
      [[ -n $OUTPUT ]] || fatal "backup requires --output FILE.tar.zst"
      [[ -z $ARCHIVE && -z $DEST ]] || fatal "backup does not accept restore-only arguments"
      ;;
    restore)
      [[ -n $ARCHIVE ]] || fatal "restore requires --archive FILE.tar.zst"
      [[ -n $DEST ]] || fatal "restore requires --dest DIR"
      [[ -z $SOURCE && -z $OUTPUT ]] || fatal "restore does not accept backup-only arguments"
      ;;
    verify)
      [[ -n $ARCHIVE ]] || fatal "verify requires --archive FILE.tar.zst"
      ;;
  esac
}

main() {
  parse_args "$@"
  check_common_dependencies
  check_tar_features

  if [[ $ACTION == verify ]]; then
    verify_action
    return
  fi

  require_root
  require_command flock
  acquire_lock
  TX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fastdir-backup.tx.XXXXXX")

  case "$ACTION" in
    backup) backup_action ;;
    restore) restore_action ;;
    verify) verify_action ;;
  esac
}

trap 'on_error "$?" "$LINENO"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap cleanup EXIT

main "$@"
