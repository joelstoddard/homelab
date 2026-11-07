locals {
  nb_vm = data.netbox_virtual_machines.match.vms[0]

  link = split("-", var.name)[0]
  idx  = tonumber(split("-", var.name)[1])

  # vm_id = link base + instance number: bind9-01 is 311, lancache-02 is 322.
  vm_id = (local.link == "bind9" ? 310 : 320) + local.idx
}
