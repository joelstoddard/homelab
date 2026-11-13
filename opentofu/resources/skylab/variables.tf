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
  description = "Extra NetBox request headers, e.g. the X-NetBox-Branch header. Injected via TF_VAR_netbox_headers from NETBOX_HEADERS as a JSON object; {} reads main."
  type        = map(string)
  default     = {}
}

variable "metachat_zone" {
  description = "metachat's zone, e.g. example.net; the TURN record is turn.<zone>. From secrets.env."
  type        = string
}

variable "metachat_zone_id" {
  description = "Cloudflare zone ID of metachat_zone. From secrets.env."
  type        = string
}

variable "talos_skylab_schematic_id" {
  description = "Image Factory schematic of skylab's Talos image, the snapshot's talos_schematic label. Injected from versions.env by the Makefile."
  type        = string
}
