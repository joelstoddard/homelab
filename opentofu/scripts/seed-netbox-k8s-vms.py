#!/usr/bin/env python3
"""Seed the 12 Talos k8s VMs into NetBox.

NetBox is the homelab's source of truth. Both OpenTofu
(opentofu/modules/k8s-vm) and the Ansible NetBox inventory read these
records, so they must exist before `make -C opentofu apply` or
`make -C ansible apply-talos`.

This script is idempotent: it creates missing objects and updates drifted
ones, keyed by name. Re-run it freely.

Conventions (mirrored by opentofu/modules/k8s-vm/main.tf):
  - servers (control plane): vm_id 100+N, mac 52:54:00:00:01:NN
  - agents  (workers):       vm_id 200+N, mac 52:54:00:00:02:NN
  - platform slug `talos`  -> lands the VM in the `talos` inventory group
  - each VM is pinned to its NUC via the VM.device field; OpenTofu asserts
    NetBox's device assignment matches the per-NUC resources/ dir.

Environment:
  NETBOX_API / NETBOX_URL   NetBox base URL (NETBOX_API wins)
  NETBOX_TOKEN              API token with write scope

Usage:
  ./seed-netbox-k8s-vms.py            # apply
  ./seed-netbox-k8s-vms.py --dry-run  # print intended changes only
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    import pynetbox
except ImportError:
    sys.exit("pynetbox not installed. `pip install pynetbox` (it's in ansible/requirements.txt).")

# --- Topology ----------------------------------------------------------
# Placement must match the per-NUC dirs under opentofu/resources/.
CLUSTER_NAME = "homelab"
CLUSTER_TYPE = "proxmox"
PLATFORM_SLUG = "talos"
PLATFORM_NAME = "Talos Linux"

# name -> NUC device it lives on (capitalized to match NetBox device names).
PLACEMENT = {
    "k8s-server-01": "Rumba",
    "k8s-agent-01": "Rumba",
    "k8s-agent-02": "Rumba",
    "k8s-server-02": "Tango",
    "k8s-agent-03": "Tango",
    "k8s-agent-04": "Tango",
    "k8s-server-03": "Salsa",
    "k8s-agent-05": "Salsa",
    "k8s-agent-06": "Salsa",
    "k8s-server-04": "Samba",
    "k8s-agent-07": "Samba",
    "k8s-agent-08": "Samba",
}

# Per-role hardware. NetBox stores memory + disk in MB; the k8s-vm module
# converts disk MB -> GB (floor(disk/1000)).
SPECS = {
    "server": {"vcpus": 2, "memory": 4096, "disk": 40000},   # 40 GB
    "agent": {"vcpus": 4, "memory": 8192, "disk": 100000},   # 100 GB
}

# Deterministic management IPs on the documented LAN (192.168.1.0/24).
# servers -> .111-.114, agents -> .121-.128. Adjust to your free range.
IP_PREFIX = "192.168.1"
SERVER_IP_BASE = 110  # server-NN -> .(110+N)
AGENT_IP_BASE = 120   # agent-NN  -> .(120+N)
IP_CIDR = "/24"
PRIMARY_NIC = "eth0"


def role_of(name: str) -> str:
    return "server" if name.startswith("k8s-server-") else "agent"


def index_of(name: str) -> int:
    return int(name[-2:])


def mac_of(name: str) -> str:
    n = index_of(name)
    group = "01" if role_of(name) == "server" else "02"
    return f"52:54:00:00:{group}:{n:02d}"


def ip_of(name: str) -> str:
    n = index_of(name)
    base = SERVER_IP_BASE if role_of(name) == "server" else AGENT_IP_BASE
    return f"{IP_PREFIX}.{base + n}{IP_CIDR}"


class Seeder:
    def __init__(self, nb, dry_run: bool):
        self.nb = nb
        self.dry_run = dry_run

    def log(self, action: str, what: str) -> None:
        prefix = "WOULD " if self.dry_run else ""
        print(f"  {prefix}{action}: {what}")

    def ensure(self, endpoint, key_field, key_value, defaults):
        """Get-or-create-or-update a NetBox object keyed by key_field."""
        obj = endpoint.get(**{key_field: key_value})
        if obj is None:
            self.log("create", f"{endpoint.name} {key_value}")
            if self.dry_run:
                return None
            return endpoint.create(**{key_field: key_value, **defaults})
        # Patch any drifted fields.
        changed = {}
        for field, want in defaults.items():
            have = getattr(obj, field, None)
            have_id = getattr(have, "id", have)
            want_id = getattr(want, "id", want)
            if have_id != want_id:
                changed[field] = want
        if changed:
            self.log("update", f"{endpoint.name} {key_value}: {list(changed)}")
            if not self.dry_run:
                obj.update(changed)
        return obj

    def run(self) -> None:
        nb = self.nb

        print("Prerequisites:")
        ctype = self.ensure(
            nb.virtualization.cluster_types, "slug", CLUSTER_TYPE,
            {"name": CLUSTER_TYPE.capitalize()},
        )
        cluster = self.ensure(
            nb.virtualization.clusters, "name", CLUSTER_NAME,
            {"type": ctype} if ctype else {},
        )
        platform = self.ensure(
            nb.dcim.platforms, "slug", PLATFORM_SLUG,
            {"name": PLATFORM_NAME},
        )

        for tag_slug, tag_name in (("k8s", "k8s"),
                                   ("k8s-server", "k8s-server"),
                                   ("k8s-agent", "k8s-agent")):
            self.ensure(nb.extras.tags, "slug", tag_slug, {"name": tag_name})

        print("VMs:")
        for name, node in PLACEMENT.items():
            self._seed_vm(name, node, cluster, platform)

    def _seed_vm(self, name, node, cluster, platform):
        nb = self.nb
        role = role_of(name)
        spec = SPECS[role]
        device = nb.dcim.devices.get(name=node)
        if device is None:
            self.log("SKIP", f"{name}: NUC device '{node}' not found in NetBox")
            return

        defaults = {
            "cluster": cluster,
            "device": device,
            "platform": platform,
            "status": "active",
            "vcpus": spec["vcpus"],
            "memory": spec["memory"],
            "disk": spec["disk"],
            "tags": [{"slug": "k8s"}, {"slug": f"k8s-{role}"}],
        }
        vm = self.ensure(nb.virtualization.virtual_machines, "name", name, defaults)
        if vm is None:  # dry-run create
            self.log("would-assign", f"{name}: {mac_of(name)} / {ip_of(name)}")
            return

        # Primary interface + management IP (so inventory ansible_host and
        # the module's planned_ip resolve).
        iface = nb.virtualization.interfaces.get(virtual_machine_id=vm.id, name=PRIMARY_NIC)
        if iface is None:
            self.log("create", f"{name} interface {PRIMARY_NIC} ({mac_of(name)})")
            if not self.dry_run:
                iface = nb.virtualization.interfaces.create(
                    virtual_machine=vm.id, name=PRIMARY_NIC, mac_address=mac_of(name),
                )
        elif str(iface.mac_address or "").lower() != mac_of(name).lower():
            self.log("update", f"{name} interface MAC -> {mac_of(name)}")
            if not self.dry_run:
                iface.update({"mac_address": mac_of(name)})

        if self.dry_run:
            self.log("would-assign", f"{name}: ip {ip_of(name)} primary")
            return

        ip = nb.ipam.ip_addresses.get(address=ip_of(name))
        if ip is None:
            self.log("create", f"{name} ip {ip_of(name)}")
            ip = nb.ipam.ip_addresses.create(
                address=ip_of(name),
                assigned_object_type="virtualization.vminterface",
                assigned_object_id=iface.id,
                status="active",
            )
        if getattr(vm, "primary_ip4", None) is None or vm.primary_ip4.id != ip.id:
            self.log("update", f"{name} primary_ip4 -> {ip_of(name)}")
            vm.update({"primary_ip4": ip.id})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print changes without applying")
    args = parser.parse_args()

    url = os.environ.get("NETBOX_API") or os.environ.get("NETBOX_URL")
    token = os.environ.get("NETBOX_TOKEN")
    if not url or not token:
        return "set NETBOX_API (or NETBOX_URL) and NETBOX_TOKEN in the environment."

    nb = pynetbox.api(url, token=token)
    Seeder(nb, args.dry_run).run()
    print("Done." if not args.dry_run else "Dry run complete (no changes written).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
