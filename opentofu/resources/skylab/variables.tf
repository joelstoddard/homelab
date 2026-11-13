variable "netbox_url" {
  description = "NetBox base URL. Injected via TF_VAR_netbox_url from NETBOX_URL."
  type        = string
}

variable "netbox_token" {
  description = "NetBox API token. Injected via TF_VAR_netbox_token from NETBOX_TOKEN."
  type        = string
  sensitive   = true
}

variable "netbox_headers" {
  description = "JSON object of extra NetBox request headers, e.g. the X-NetBox-Branch header. Injected via TF_VAR_netbox_headers from NETBOX_HEADERS; empty reads main."
  type        = string
  default     = ""
}

variable "talos_skylab_schematic_id" {
  description = "Image Factory schematic of skylab's Talos image, the snapshot's talos_schematic label. Injected from versions.env by the Makefile."
  type        = string
}
