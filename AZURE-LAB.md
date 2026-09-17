# The azure-lab fork

This branch (`azure-lab`) is upstream cloud-cml 2.9.0 plus a small set of
Azure patches, consumed as a submodule by
[cml-phoenix](https://github.com/itsAmeMario0o/cml-phoenix). Each patch is
a few lines with an `azure-lab fork:` comment at the change, so an upstream
merge can be resolved patch by patch. The decisions behind them are ADRs in
the consuming repo; the numbers below refer to those.

## What the fork changes

| Area | Change | Where |
|---|---|---|
| Target | Azure enabled, azurerm pinned to 4.x | `modules/deploy/azure.tf`, `aws.tf` |
| Network | Deploys into an existing VNet, subnet, and static public IP owned by a longer-lived root, with a static private IP (ADR 0002, 0003) | `modules/deploy/azure/main.tf` |
| NIC | IP forwarding and accelerated networking on (ADR 0003) | `modules/deploy/azure/main.tf` |
| Disk | OS disk type from config; a persistent data disk attached at LUN 0 (ADR 0002, 0005) | `modules/deploy/azure/main.tf` |
| Images | `05-persist.sh` keeps refplat images and exports on the data disk and copies only what is missing on a rebuild | `modules/deploy/data/05-persist.sh`, `cloud-config.txt` |
| Cost | SAS validity from config; optional spot priority | `modules/deploy/azure/main.tf` |
| Routed lab path | Two NSG rules and the transit network script, below (ADR 0003) | `modules/deploy/azure/main.tf`, `modules/deploy/data/06-transit.sh` |

## The routed lab path

Lab nodes reach VMs in the VNet (ISE, FTD) at their own addresses, with no
NAT, so RADIUS sees each switch as itself and Change of Authorization has a
way back. The CML host is a layer 3 hop between a transit bridge and its
VNet NIC. Four pieces make that work, and all four are required.

1. **IP forwarding on the CML NIC**, so Azure accepts packets the NIC
   neither sourced nor is addressed to.
2. **A user-defined route on the far subnet** sending the lab summary
   (`lab_summary_cidr`, default `10.100.0.0/16`) to the CML NIC as a virtual
   appliance. That route lives in the consuming repo's persistent root, not
   here.
3. **Two NSG rules on the CML NIC**, a matched pair:

   | Rule | Direction | Source | Destination |
   |---|---|---|---|
   | `lab-transit-in` (400) | Inbound | `apps_subnet_cidr` | `lab_summary_cidr` |
   | `lab-transit-out` (410) | Outbound | `lab_summary_cidr` | `apps_subnet_cidr` |

   Both are created only when `azure.apps_subnet_cidr` is set in the config.

   The outbound rule is not redundant with Azure's default
   `AllowVnetOutBound`. The `VirtualNetwork` service tag expands per NIC
   from that NIC's effective routes. The far subnet has the route for the
   lab summary, so NICs there count the lab range as VirtualNetwork; the CML
   subnet has no such route, so on the CML NIC a forwarded packet with a lab
   source matches neither `AllowVnetOutBound` nor `AllowInternetOutBound`,
   and `DenyAllOutBound` drops it with no ICMP and no log. The symptom is a
   request visible leaving `eth0` in a host capture that never arrives at
   the destination VM. `az network nic list-effective-nsg` shows the
   per-NIC expansion under `tagMap`; `az network watcher test-ip-flow`
   cannot model it, because it refuses a local IP that is not the NIC's own.

4. **The transit network on the host**, built by `06-transit.sh` from
   `cml.sh` postprocess: a libvirt network in routed mode named `transit`
   on bridge `bridge1` at `10.100.0.1/24`, with a static route for the rest
   of the lab summary to the lab edge at `10.100.0.2`, autostarted. libvirt
   places the bridge in its `libvirt-routed` firewalld zone, whose shipped
   policies accept forwarding both ways; a plain netplan bridge is rejected
   by firewalld with "administratively prohibited".

Two naming rules the script depends on, both learned the hard way:

- The bridge must be named `bridgeN`. The CML controller's external
  connector scan only admits `^(bridge|virbr|vlan|local)[0-9]{1,4}$`, and
  `bridge0` is reserved for the system bridge.
- A customize script must be named `NN-word.sh` or `NN-two_words.sh`.
  `postprocess` selects files with `[0-9]{2}-[[:alnum:]_]+\.sh`; a second
  hyphen fails the match and the script is copied to `/provision` and
  skipped without any message.

After a build, the controller lists the new connector only after a rescan:
`PUT /api/v0/system/external_connectors`. A lab's external connector node
then uses `bridge1` as its configuration value.

## Config keys the fork adds

Under `azure:` in the config file: `vnet_name`, `subnet_name`,
`private_ip`, `public_ip_name`, `data_disk_id`, `os_disk_type`,
`sas_validity`, `spot`, `apps_subnet_cidr`, `lab_summary_cidr`. Under
`app.customize`: `05-persist.sh`, `06-transit.sh`.
