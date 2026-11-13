# resources/skylab/

Declares skylab, the public cluster's one Talos node, on Hetzner Cloud: a
`cx33` server booted from a Talos snapshot with its machine config as
`user_data`, a primary IPv4 with its DNS-only `turn` record on Cloudflare, a
firewall, and Forgejo's 10 GB Volume. The
design is in `docs/design/skylab-provisioning.md`; the Volume is in
`docs/design/skylab-forgejo.md`, "Storage", and the firewall in
`docs/design/skylab-security.md`, "Hetzner firewall", and the `turn` record
in `docs/design/skylab-ingress.md`, "TURN". The proxied records and the
tunnel are in `../cloudflare/`, ungated, so a run without the branch never
deletes them.

## The gate

Every billable resource is created only while NetBox places skylab at a
site whose name is a Hetzner `eu-central` city. Main does not, so a blanket
`make -C opentofu apply` plans nothing. The NetBox branch does, and is read
by exporting `NETBOX_HEADERS='{"X-NetBox-Branch":"<schema_id>"}'`.

## Before the first run

1. Create the Hetzner project "Homelab - Public" and an API token with
   read/write access in it.
2. Create `secrets.env` here, SOPS-encrypted:

   ```bash
   sops opentofu/resources/skylab/secrets.env
   ```

   | Line | Holds |
   |---|---|
   | `HCLOUD_TOKEN` | The token from step 1 |
   | `CLOUDFLARE_API_TOKEN` | The token in `../cloudflare/secrets.env` |
   | `TF_VAR_metachat_zone`, `TF_VAR_metachat_zone_id` | metachat's zone (`example.net`) and its zone ID |

   The hcloud provider fails without a token even when the gate is closed,
   so the Makefile refuses every run that includes this directory until the
   file exists.

## Running it

With the branch header exported:

```bash
make -C ansible apply-talos CLUSTER=skylab TAGS=config   # user_data
make -C opentofu skylab-image                            # bills a temporary server
make -C opentofu check LIMIT=skylab
make -C opentofu apply LIMIT=skylab
```

`skylab-image` is never part of `apply`. After the apply, enter the primary
IPv4 on the branch record; the `netbox_primary_ipv4` check warns until it
matches.

## Inputs

| Variable | Source |
|---|---|
| `netbox_url`, `netbox_token` | `NETBOX_URL` / `NETBOX_TOKEN`, exported by `opentofu/Makefile` |
| `netbox_headers` | `NETBOX_HEADERS`, mirrored by `opentofu/Makefile`; empty reads main |
| `talos_skylab_schematic_id` | `TALOS_SKYLAB_SCHEMATIC_ID` in `versions.env` |
| `metachat_zone`, `metachat_zone_id` | `secrets.env` |
| `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN` (environment, not variables) | `secrets.env` |
