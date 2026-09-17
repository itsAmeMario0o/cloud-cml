#!/bin/bash
#
# 06-transit-bridge.sh: the routed transit bridge between lab nodes and the
# VNet, with no NAT on the path.
#
# Creates br-transit at 10.100.0.1/24 with no member interfaces (CML plugs
# node taps in through an external connector), routes the rest of
# 10.100.0.0/16 to the C8000v lab edge at 10.100.0.2, and keeps
# net.ipv4.ip_forward on. Both settings live in files under /etc so they
# survive the reboot that ends the install and every reboot after it.
# Warns when an nftables masquerade rule could cover the transit range,
# because NAT on this path breaks RADIUS CoA and per-device identity.
#
# Runs from cml.sh postprocess as root after the CML install. Idempotent:
# rewriting the same two files and applying them again changes nothing.
#
# DRY_RUN=1 prints commands instead of running them and PRETEND_* values
# replace the probes, for the tests on macOS. Stays bash 3.2 compatible.
#
# Part of the azure-lab fork. ADR 0003 in cml-azure-lab.
set -euo pipefail

BRIDGE="${BRIDGE:-br-transit}"
BRIDGE_ADDR="${BRIDGE_ADDR:-10.100.0.1/24}"
LAB_SUMMARY="${LAB_SUMMARY:-10.100.0.0/16}"
LAB_EDGE="${LAB_EDGE:-10.100.0.2}"
NETPLAN_FILE="${NETPLAN_FILE:-/etc/netplan/60-transit-bridge.yaml}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/60-transit-bridge.conf}"
LOG_DIR="${LOG_DIR:-/var/log/provision}"
DRY_RUN="${DRY_RUN:-0}"
PRETEND_ADDR="${PRETEND_ADDR:-}"
PRETEND_MASQ="${PRETEND_MASQ:-}"

log() { echo "[06-transit-bridge] $*"; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

# write_file PATH MODE CONTENT: create or replace a root-owned file.
write_file() {
  local path="$1" mode="$2" content="$3"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ write ${path} mode ${mode}:"
    printf '%s\n' "${content}" | sed 's/^/    /'
    return 0
  fi
  install -m "${mode}" /dev/null "${path}"
  printf '%s\n' "${content}" > "${path}"
}

write_netplan() {
  # No member interfaces on purpose: CML attaches node taps through the
  # external connector. STP off and no forward delay so a tap forwards as
  # soon as the node boots.
  write_file "${NETPLAN_FILE}" 0600 "network:
  version: 2
  bridges:
    ${BRIDGE}:
      interfaces: []
      addresses: [${BRIDGE_ADDR}]
      parameters:
        stp: false
        forward-delay: 0
      routes:
        - to: ${LAB_SUMMARY}
          via: ${LAB_EDGE}"
  run netplan apply
}

write_sysctl() {
  write_file "${SYSCTL_FILE}" 0644 "net.ipv4.ip_forward = 1"
  run sysctl -q -p "${SYSCTL_FILE}"
}

bridge_addr() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_ADDR}"
  else
    ip -o -4 addr show "${BRIDGE}" 2>/dev/null | awk '{print $4}'
  fi
}

masquerade_rules() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_MASQ}"
  else
    nft list ruleset 2>/dev/null | grep -i masquerade || true
  fi
}

# libvirt masquerades 192.168.255.0/24 for the NAT connector and names that
# source. A rule naming the transit range, or one with no source at all,
# would NAT the RADIUS path.
check_no_nat() {
  local rules
  rules="$(masquerade_rules)"
  if [[ -z "${rules}" ]]; then
    log "no masquerade rules on the host"
    return 0
  fi
  if grep -qE "${LAB_SUMMARY}|10\.100\." <<<"${rules}" || grep -qvE "saddr" <<<"${rules}"; then
    log "WARN: a masquerade rule may cover ${LAB_SUMMARY}; CoA breaks behind NAT (ADR 0003):"
    printf '%s\n' "${rules}" | sed 's/^/    /'
  else
    log "masquerade rules leave ${LAB_SUMMARY} alone"
  fi
}

verify() {
  local addr
  addr="$(bridge_addr)"
  if [[ "${addr}" == "${BRIDGE_ADDR}" ]]; then
    log "${BRIDGE} holds ${BRIDGE_ADDR}"
    return 0
  fi
  log "FAIL: ${BRIDGE} address '${addr:-none}', expected ${BRIDGE_ADDR}"
  return 1
}

main() {
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/06-transit-bridge.log") 2>&1
  log "start $(date -u +%FT%TZ)"
  write_netplan
  write_sysctl
  check_no_nat
  verify
  log "done"
}

main "$@"
