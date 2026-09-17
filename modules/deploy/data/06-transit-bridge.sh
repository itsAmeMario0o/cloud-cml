#!/bin/bash
#
# 06-transit-bridge.sh: the routed transit network between lab nodes and
# the VNet, with no NAT on the path.
#
# Defines a libvirt network in routed mode named "transit": bridge1 at
# 10.100.0.1/24 with no DHCP, and a static route for the rest of
# 10.100.0.0/16 via the C8000v lab edge at 10.100.0.2. libvirt creates
# the bridge, turns on forwarding, and files the bridge under its own
# firewalld zone and policies (libvirt-routed-in and -out), which is what
# lets the host forward between bridge1 and the VNet NIC without any
# hand-written firewall rule. Autostart makes it survive every reboot.
# CML's NAT connector rides the same libvirt mechanism, so nothing in CML
# is changed; the controller finds bridge1 on its next connector scan.
#
# The bridge is named bridge1, not br-transit: the controller's connector
# scan only admits bridges matching ^(bridge|virbr|vlan|local)[0-9]{1,4}$
# (simple_drivers/low_level_driver/disk_utils.py), and bridge0 is reserved
# for the system bridge.
#
# Runs from cml.sh postprocess as root after the CML install. Idempotent:
# an already defined network is left alone, only autostart and start are
# reasserted. A leftover bridge1 that libvirt does not own (an earlier
# netplan version of this script) is removed first so the name is free.
#
# DRY_RUN=1 prints commands instead of running them and PRETEND_* values
# replace the probes, for the tests on macOS. Stays bash 3.2 compatible.
#
# Part of the azure-lab fork. ADR 0003 in cml-azure-lab.
set -euo pipefail

NET_NAME="${NET_NAME:-transit}"
BRIDGE="${BRIDGE:-bridge1}"
BRIDGE_IP="${BRIDGE_IP:-10.100.0.1}"
BRIDGE_MASK="${BRIDGE_MASK:-255.255.255.0}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.100.0.1/24}"
LAB_SUMMARY_NET="${LAB_SUMMARY_NET:-10.100.0.0}"
LAB_SUMMARY_PREFIX="${LAB_SUMMARY_PREFIX:-16}"
LAB_EDGE="${LAB_EDGE:-10.100.0.2}"
OLD_NETPLAN_FILE="${OLD_NETPLAN_FILE:-/etc/netplan/60-transit-bridge.yaml}"
LOG_DIR="${LOG_DIR:-/var/log/provision}"
DRY_RUN="${DRY_RUN:-0}"
PRETEND_NET_DEFINED="${PRETEND_NET_DEFINED:-0}"
PRETEND_NET_ACTIVE="${PRETEND_NET_ACTIVE:-0}"
PRETEND_STRAY_BRIDGE="${PRETEND_STRAY_BRIDGE:-0}"
PRETEND_ADDR="${PRETEND_ADDR:-}"
PRETEND_ROUTE="${PRETEND_ROUTE:-}"
PRETEND_MASQ="${PRETEND_MASQ:-}"

log() { echo "[06-transit-bridge] $*"; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

net_defined() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    [[ "${PRETEND_NET_DEFINED}" == "1" ]]
  else
    virsh net-info "${NET_NAME}" >/dev/null 2>&1
  fi
}

net_active() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    [[ "${PRETEND_NET_ACTIVE}" == "1" ]]
  else
    virsh net-info "${NET_NAME}" 2>/dev/null | grep -q '^Active:.*yes'
  fi
}

bridge_exists() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    [[ "${PRETEND_STRAY_BRIDGE}" == "1" ]]
  else
    [[ -d "/sys/class/net/${BRIDGE}" ]]
  fi
}

# An earlier version of this script built bridge1 with netplan. libvirt
# refuses to start a network whose bridge already exists, so clear that
# out first. Only runs when libvirt does not own the network yet.
remove_stray_bridge() {
  if net_defined; then
    return 0
  fi
  if bridge_exists; then
    log "removing ${BRIDGE} that libvirt does not own"
    run ip link delete "${BRIDGE}"
  fi
  if [[ "${DRY_RUN}" == "1" || -f "${OLD_NETPLAN_FILE}" ]]; then
    run rm -f "${OLD_NETPLAN_FILE}"
    run netplan apply
  fi
}

network_xml() {
  cat <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='route'/>
  <bridge name='${BRIDGE}' stp='off' delay='0'/>
  <ip address='${BRIDGE_IP}' netmask='${BRIDGE_MASK}'/>
  <route address='${LAB_SUMMARY_NET}' prefix='${LAB_SUMMARY_PREFIX}' gateway='${LAB_EDGE}'/>
</network>
EOF
}

define_network() {
  local xml
  if net_defined; then
    log "network ${NET_NAME} already defined"
  else
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "+ virsh net-define <xml>:"
      network_xml | sed 's/^/    /'
    else
      xml="$(mktemp)"
      network_xml > "${xml}"
      virsh net-define "${xml}"
      rm -f "${xml}"
    fi
  fi
  run virsh net-autostart "${NET_NAME}"
  if net_active; then
    log "network ${NET_NAME} already active"
  else
    run virsh net-start "${NET_NAME}"
  fi
}

bridge_addr() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_ADDR}"
  else
    ip -o -4 addr show "${BRIDGE}" 2>/dev/null | awk '{print $4}'
  fi
}

summary_route() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_ROUTE}"
  else
    ip route show "${LAB_SUMMARY_NET}/${LAB_SUMMARY_PREFIX}" 2>/dev/null
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
# would NAT the RADIUS path and break CoA.
check_no_nat() {
  local rules summary
  summary="${LAB_SUMMARY_NET}/${LAB_SUMMARY_PREFIX}"
  rules="$(masquerade_rules)"
  if [[ -z "${rules}" ]]; then
    log "no masquerade rules on the host"
    return 0
  fi
  if grep -qE "${summary}|10\.100\." <<<"${rules}" || grep -qvE "saddr" <<<"${rules}"; then
    log "WARN: a masquerade rule may cover ${summary}; CoA breaks behind NAT (ADR 0003):"
    printf '%s\n' "${rules}" | sed 's/^/    /'
  else
    log "masquerade rules leave ${summary} alone"
  fi
}

verify() {
  local addr route
  addr="$(bridge_addr)"
  if [[ "${addr}" != "${BRIDGE_CIDR}" ]]; then
    log "FAIL: ${BRIDGE} address '${addr:-none}', expected ${BRIDGE_CIDR}"
    return 1
  fi
  log "${BRIDGE} holds ${BRIDGE_CIDR}"
  route="$(summary_route)"
  if ! grep -q "via ${LAB_EDGE}" <<<"${route}"; then
    log "FAIL: no route to ${LAB_SUMMARY_NET}/${LAB_SUMMARY_PREFIX} via ${LAB_EDGE}, got '${route:-none}'"
    return 1
  fi
  log "${LAB_SUMMARY_NET}/${LAB_SUMMARY_PREFIX} routes via ${LAB_EDGE}"
}

main() {
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/06-transit-bridge.log") 2>&1
  log "start $(date -u +%FT%TZ)"
  remove_stray_bridge
  define_network
  check_no_nat
  verify
  log "done"
}

main "$@"
