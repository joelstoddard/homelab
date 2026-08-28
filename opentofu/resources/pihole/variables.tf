variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint. Injected via TF_VAR_proxmox_endpoint from opentofu/secrets.sops.yaml."
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token. Injected via TF_VAR_proxmox_api_token from ansible/inventory/group_vars/proxmox.sops.yaml."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification on the Proxmox endpoint."
  type        = bool
  default     = true
}

variable "operator_ssh_private_key_path" {
  description = "Path to the operator's SSH private key. Used to drive the LXC's remote-exec installer + gravity-apply. Override for non-RSA keypairs (e.g. \"~/.ssh/id_ed25519\")."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "operator_ssh_public_key_path" {
  description = "Path to the operator's SSH public key. Injected into the LXC's root authorized_keys via the container's initialization block."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "pihole_node" {
  description = "Proxmox node hosting the Pi-hole LXC."
  type        = string
  default     = "Rumba"
}

variable "pihole_vm_id" {
  description = "Proxmox VM ID for the Pi-hole container."
  type        = number
  default     = 200
}

variable "pihole_hostname" {
  description = "LXC hostname."
  type        = string
  default     = "pihole"
}

variable "pihole_static_ipv4_cidr" {
  description = "Pi-hole static IPv4 in CIDR form. Resource-scoped; injected via TF_VAR_pihole_static_ipv4_cidr from opentofu/resources/pihole/secrets.sops.yaml."
  type        = string
}

variable "lan_gateway" {
  description = "LAN gateway IPv4. Shared across resources; injected via TF_VAR_lan_gateway from opentofu/secrets.sops.yaml."
  type        = string
}

variable "pihole_web_password" {
  description = "Pi-hole admin/API password. Resource-scoped; injected via TF_VAR_pihole_web_password from opentofu/resources/pihole/secrets.sops.yaml."
  type        = string
  sensitive   = true
}

variable "pihole_upstream_dns" {
  description = "Upstream resolvers for Pi-hole to forward to. Must have at least one entry; the second (if present) becomes PIHOLE_DNS_2."
  type        = list(string)
  default     = ["9.9.9.9", "1.1.1.1"]

  validation {
    condition     = length(var.pihole_upstream_dns) >= 1
    error_message = "pihole_upstream_dns must contain at least one resolver."
  }
}

variable "pihole_template_url" {
  description = "URL of the Debian 12 LXC template."
  type        = string
  default     = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pihole_template_file_name" {
  description = "On-disk filename for the LXC template."
  type        = string
  default     = "debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pihole_groups" {
  description = "Pi-hole groups to manage, keyed by group name with the group's description as the value. Not secret — group names are policy, not inventory, so these stay in git. \"Default\" is Pi-hole's built-in group (ID 0) and must not be listed; clients reference it by name regardless."
  type        = map(string)

  default = {
    Exclusions = "Clients in this group bypass all ad-blocking."
  }

  validation {
    condition     = !contains(keys(var.pihole_groups), "Default")
    error_message = "\"Default\" is Pi-hole's built-in group (ID 0) and cannot be managed as a resource — declaring it would hand OpenTofu the power to destroy it and orphan every unassigned client. Remove it from pihole_groups; clients may still name it in their groups list."
  }
}

variable "pihole_clients" {
  description = <<-EOT
    Pi-hole clients keyed by device name, which is surfaced as the client's
    comment in the Pi-hole UI. Resource-scoped and secret in full: on a public
    repo a client list is a household device inventory, so names and MACs alike
    live in this directory's SOPS-encrypted secrets.env and reach OpenTofu via
    TF_VAR_pihole_clients. Nothing about the client set enters git.

    `mac` is six colon-separated hex octets. `groups` names must resolve through
    local.group_ids — either "Default" or a key of var.pihole_groups — and
    defaults to Exclusions, the whole reason a client gets declared here.

    Defaults to empty so `make lint` and `make check` pass on a checkout whose
    secrets.env has not been populated yet.
  EOT

  type = map(object({
    mac    = string
    groups = optional(list(string), ["Exclusions"])
  }))

  default   = {}
  sensitive = true

  validation {
    condition = alltrue([
      for client in values(var.pihole_clients) :
      can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", client.mac))
    ])
    error_message = "Every pihole_clients entry needs a `mac` of six colon-separated hex octets (e.g. \"aa:bb:cc:dd:ee:ff\"). The offending value is withheld here because the variable is sensitive — inspect it with `sops opentofu/resources/pihole/secrets.env`."
  }

  validation {
    condition = alltrue([
      for client in values(var.pihole_clients) : length(client.groups) > 0
    ])
    error_message = "Every pihole_clients entry needs at least one group. An empty list would leave the client registered but ungrouped, which Pi-hole treats as Default anyway — say so explicitly."
  }

  validation {
    condition = alltrue([
      for client in values(var.pihole_clients) : alltrue([
        for name in client.groups :
        contains(concat(["Default"], keys(var.pihole_groups)), name)
      ])
    ])
    error_message = "A pihole_clients entry names a group that does not exist. Group names must be \"Default\" or a key of var.pihole_groups; without this check the failure surfaces as an opaque local.group_ids index error."
  }
}

variable "pihole_adlists" {
  description = "Adlist URLs to seed into Pi-hole's Default group. Defaults to the set extracted from teleporter backup 2026-05-10."
  type        = list(string)

  validation {
    condition     = length(var.pihole_adlists) == length(toset(var.pihole_adlists))
    error_message = "pihole_adlists contains duplicate URLs. for_each toset() would silently dedupe; surfacing it here so a copy-paste typo doesn't quietly collapse two intended entries into one."
  }

  default = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
    "https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt",
    "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Spam/hosts",
    "https://v.firebog.net/hosts/static/w3kbl.txt",
    "https://raw.githubusercontent.com/matomo-org/referrer-spam-blacklist/master/spammers.txt",
    "https://someonewhocares.org/hosts/zero/hosts",
    "https://raw.githubusercontent.com/VeleSila/yhosts/master/hosts",
    "https://winhelp2002.mvps.org/hosts.txt",
    "https://v.firebog.net/hosts/neohostsbasic.txt",
    "https://raw.githubusercontent.com/RooneyMcNibNug/pihole-stuff/master/SNAFU.txt",
    "https://paulgb.github.io/BarbBlock/blacklists/hosts-file.txt",
    "https://adaway.org/hosts.txt",
    "https://v.firebog.net/hosts/AdguardDNS.txt",
    "https://v.firebog.net/hosts/Admiral.txt",
    "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
    "https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt",
    "https://v.firebog.net/hosts/Easylist.txt",
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext",
    "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts",
    "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts",
    "https://raw.githubusercontent.com/jdlingyu/ad-wars/master/hosts",
    "https://v.firebog.net/hosts/Easyprivacy.txt",
    "https://v.firebog.net/hosts/Prigent-Ads.txt",
    "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts",
    "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
    "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt",
    "https://www.github.developerdan.com/hosts/lists/ads-and-tracking-extended.txt",
    "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/android-tracking.txt",
    "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt",
    "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/AmazonFireTV.txt",
    "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-blocklist.txt",
    "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt",
    "https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt",
    "https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt",
    "https://v.firebog.net/hosts/Prigent-Crypto.txt",
    "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts",
    "https://bitbucket.org/ethanr/dns-blacklists/raw/8575c9f96e5b4a1308f2f12394abd86d0927a4a0/bad_lists/Mandiant_APT1_Report_Appendix_D.txt",
    "https://phishing.army/download/phishing_army_blocklist_extended.txt",
    "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt",
    "https://v.firebog.net/hosts/RPiList-Malware.txt",
    "https://v.firebog.net/hosts/RPiList-Phishing.txt",
    "https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt",
    "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts",
    "https://urlhaus.abuse.ch/downloads/hostfile/",
    "https://malware-filter.gitlab.io/malware-filter/phishing-filter-hosts.txt",
    "https://v.firebog.net/hosts/Prigent-Malware.txt",
  ]
}
