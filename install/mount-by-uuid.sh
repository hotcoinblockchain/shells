#!/usr/bin/env bash

### curl -sSL https://raw.githubusercontent.com/hotcoinblockchain/shells/main/install/mount-by-uuid.sh | bash -s /dev/vdb1 /coins

set -euo pipefail

########################################
# Usage:
#   ./mount-by-uuid.sh /dev/vdb1 /coins
########################################

DEVICE="${1:-}"
MOUNT_POINT="${2:-}"

########################################
# Utils
########################################

log() {
  echo "[$(date '+%F %T')] $*"
}

error_exit() {
  echo "[ERROR] $1"
  exit 1
}

########################################
# Parameter Check
########################################

if [[ -z "$DEVICE" || -z "$MOUNT_POINT" ]]; then
  error_exit "Usage: $0 <device> <mount_point>"
fi

if [[ ! -b "$DEVICE" ]]; then
  error_exit "Device not found: $DEVICE"
fi

########################################
# Get UUID
########################################

UUID=$(blkid -s UUID -o value "$DEVICE" || true)

if [[ -z "$UUID" ]]; then
  error_exit "Cannot get UUID for $DEVICE"
fi

log "Device: $DEVICE"
log "UUID: $UUID"
log "Mount point: $MOUNT_POINT"

########################################
# Create Mount Directory
########################################

if [[ ! -d "$MOUNT_POINT" ]]; then
  log "Creating mount directory..."
  mkdir -p "$MOUNT_POINT"
fi

########################################
# Check if already in fstab
########################################

if grep -q "$UUID" /etc/fstab; then
  log "UUID already exists in /etc/fstab, skipping fstab write."
else
  log "Writing to /etc/fstab..."
  echo "UUID=${UUID}  ${MOUNT_POINT}  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

########################################
# Mount
########################################

if mountpoint -q "$MOUNT_POINT"; then
  log "Already mounted."
else
  log "Mounting..."
  mount "$MOUNT_POINT"
fi

log "Mount completed successfully."
