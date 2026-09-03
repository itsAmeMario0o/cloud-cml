#!/bin/bash
#
# 05-persist.sh: keep refplat images and lab exports on the persistent data
# disk so a rebuilt CML host does not copy them again.
#
# Two phases:
#   pre   Run by cloud-init runcmd before cml.sh. Waits for the data disk,
#         formats it only when blank, mounts it at /data, bind-mounts
#         /data/images onto /var/lib/libvirt/images and, when images are
#         already there, empties the image list in /provision/refplat so
#         cml.sh copies only the small node definitions.
#   post  Run by cml.sh postprocess after CML is installed. Verifies the
#         bind mount survived the install, fixes ownership, logs a summary.
#
# A bind mount rather than a symlink because cml.sh decides whether to copy
# everything with `find $images -type f | wc -l`, and find does not follow a
# symlink given as its starting point.
#
# Exits nonzero on failure so it is visible in the log even though upstream
# postprocess swallows the code. Logs to /var/log/provision/05-persist-<phase>.log.
#
# DRY_RUN=1 prints commands instead of running them and replaces probes with
# PRETEND_* values. Used by tests on macOS. Stays bash 3.2 compatible.
#
# Part of the azure-lab fork. ADR 0001 and ADR 0002 in cml-azure-lab.
set -euo pipefail

PHASE="${1:-post}"
DATA_DEV="${DATA_DEV:-/dev/disk/azure/scsi1/lun0}"
DATA_MNT="${DATA_MNT:-/data}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
REFPLAT_JSON="${REFPLAT_JSON:-/provision/refplat}"
FSTAB="${FSTAB:-/etc/fstab}"
LOG_DIR="${LOG_DIR:-/var/log/provision}"
WAIT_SECS="${WAIT_SECS:-600}"
DRY_RUN="${DRY_RUN:-0}"
PRETEND_FS="${PRETEND_FS:-}"
PRETEND_IMAGE_FILES="${PRETEND_IMAGE_FILES:-0}"
PRETEND_BOUND="${PRETEND_BOUND:-0}"

log() { echo "[05-persist:${PHASE}] $*"; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

append_line() {
  local file="$1" line="$2"
  if grep -qF -- "${line}" "${file}" 2>/dev/null; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ append to ${file}: ${line}"
  else
    echo "${line}" >> "${file}"
  fi
}

wait_for_device() {
  local waited=0
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "dry run: assuming ${DATA_DEV} is present"
    return 0
  fi
  while [[ ! -e "${DATA_DEV}" ]]; do
    if [[ "${waited}" -ge "${WAIT_SECS}" ]]; then
      log "data disk ${DATA_DEV} did not appear in ${WAIT_SECS}s"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "data disk present after ${waited}s"
}

partition_fs_type() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_FS}"
  else
    blkid -s TYPE -o value "${DATA_DEV}-part1" 2>/dev/null || true
  fi
}

format_if_blank() {
  local fstype
  fstype="$(partition_fs_type)"
  if [[ -n "${fstype}" ]]; then
    log "partition already formatted as ${fstype}, keeping it"
    return 0
  fi
  log "blank disk, creating one ext4 partition"
  run parted -s "${DATA_DEV}" mklabel gpt mkpart primary ext4 0% 100%
  run udevadm settle
  run mkfs.ext4 -L cmldata "${DATA_DEV}-part1"
  # The LABEL=cmldata symlink under /dev/disk/by-label appears asynchronously
  # after mkfs; settle again so mount_data's fstab lookup by label succeeds.
  run udevadm settle
}

mount_data() {
  run mkdir -p "${DATA_MNT}"
  append_line "${FSTAB}" "LABEL=cmldata ${DATA_MNT} ext4 defaults,nofail,x-systemd.device-timeout=30 0 2"
  run mount "${DATA_MNT}"
  run mkdir -p "${DATA_MNT}/images" "${DATA_MNT}/exports"
}

image_file_count() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_IMAGE_FILES}"
  else
    (find "${DATA_MNT}/images" -type f 2>/dev/null || true) | wc -l | tr -d ' '
  fi
}

is_bound() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    [[ "${PRETEND_BOUND}" == "1" ]]
  else
    [[ "$(findmnt -n -o TARGET --target "${IMAGES_DIR}" 2>/dev/null)" == "${IMAGES_DIR}" ]]
  fi
}

bind_images() {
  run mkdir -p "${IMAGES_DIR}"
  if is_bound; then
    log "bind mount already active"
  else
    run mount --bind "${DATA_MNT}/images" "${IMAGES_DIR}"
  fi
  append_line "${FSTAB}" "${DATA_MNT}/images ${IMAGES_DIR} none bind,x-systemd.requires=${DATA_MNT} 0 0"
}

skip_image_copy_if_present() {
  local count
  count="$(image_file_count)"
  if [[ "${count}" -eq 0 ]]; then
    log "no images on the data disk yet, cml.sh will copy them"
    return 0
  fi
  log "reusing ${count} image files from ${DATA_MNT}/images, emptying refplat image list"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ jq '.images = []' ${REFPLAT_JSON}"
  else
    jq '.images = []' "${REFPLAT_JSON}" > "${REFPLAT_JSON}.tmp"
    mv "${REFPLAT_JSON}.tmp" "${REFPLAT_JSON}"
  fi
}

phase_pre() {
  wait_for_device
  format_if_blank
  mount_data
  bind_images
  skip_image_copy_if_present
  log "pre phase done"
}

phase_post() {
  if ! is_bound; then
    log "FAIL: ${IMAGES_DIR} is not a bind mount of ${DATA_MNT}/images"
    return 1
  fi
  log "bind mount active"
  if [[ "${DRY_RUN}" != "1" ]] && getent passwd virl2 >/dev/null 2>&1; then
    run chown -R virl2:virl2 "${IMAGES_DIR}"
  fi
  log "$(image_file_count) image files on the data disk"
  log "post phase done"
}

main() {
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/05-persist-${PHASE}.log") 2>&1
  log "start $(date -u +%FT%TZ)"
  case "${PHASE}" in
    pre) phase_pre ;;
    post) phase_post ;;
    *) log "unknown phase '${PHASE}', expected pre or post"; exit 2 ;;
  esac
}

main "$@"
