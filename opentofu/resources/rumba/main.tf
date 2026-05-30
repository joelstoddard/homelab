# rumba is the Proxmox cluster leader (see
# ansible/inventory/group_vars/proxmox.yaml). Cluster-storage templates
# created on the leader propagate to followers via the same Proxmox
# storage; for stage 1 the template sits on rumba's local datastores.

module "debian_12_template" {
  source = "../../modules/cloud-init-template"

  node_name       = "Rumba"
  template_name   = "debian-12-cloud"
  template_vm_id  = 9000
  image_url       = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  image_file_name = "debian-12-genericcloud-amd64.img"

  # rumba's only storage today is the directory-backed `local`; LVM-thin
  # isn't configured. Override the module's local-lvm default until
  # additional storage is wired in.
  disk_datastore_id = "local"

  cloud_init_user     = "admin"
  cloud_init_ssh_keys = [trimspace(file(pathexpand("~/.ssh/id_rsa.pub")))]
}

output "debian_12_template_vm_id" {
  value = module.debian_12_template.template_vm_id
}

module "k8s_server_01" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-server-01"
  node_name   = "Rumba"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_01" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-01"
  node_name   = "Rumba"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_02" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-02"
  node_name   = "Rumba"
  iso_file_id = module.talos_image.file_id
}

output "k8s_vms" {
  value = {
    "k8s-server-01" = module.k8s_server_01
    "k8s-agent-01"  = module.k8s_agent_01
    "k8s-agent-02"  = module.k8s_agent_02
  }
}
