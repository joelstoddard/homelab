terraform {
  required_version = ">= 1.7.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70.0"
    }
    netbox = {
      source  = "e-breuninger/netbox"
      version = "~> 4.0"
    }
  }
}
