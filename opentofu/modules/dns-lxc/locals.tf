locals {
  nb_vm = data.netbox_virtual_machines.match.vms[0]

  link = split("-", var.name)[0]
  idx  = tonumber(split("-", var.name)[1])

  # vm_id = link base + instance number: bind9-01 is 311, pihole-02 is 332.
  vm_id = { bind9 = 310, lancache = 320, pihole = 330 }[local.link] + local.idx
}
