terraform {
  required_version = ">= 1.7.0"
  required_providers {
    pihole = {
      source  = "registry.terraform.io/dklesev/pihole"
      version = "~> 1.0"
    }
    netbox = {
      source  = "e-breuninger/netbox"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
