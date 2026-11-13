# resources/skylab/

Declares skylab, the public cluster's one Talos node, on Hetzner Cloud: a
`cx33` server booted from a Talos snapshot with its machine config as
`user_data`, a primary IPv4, a firewall, and Forgejo's 10 GB Volume. The
design is in `docs/design/skylab-provisioning.md`; the Volume is in
`docs/design/skylab-forgejo.md`, "Storage", and the firewall in
`docs/design/skylab-security.md`, "Hetzner firewall".

## The gate

Every billable resource is created only while NetBox places skylab at a
site whose name is a Hetzner `eu-central` city. Main does not, so a blanket
`make -C opentofu apply` plans nothing. The NetBox branch does, and is read
by exporting `NETBOX_HEADERS='{"X-NetBox-Branch":"<schema_id>"}'`.

## Before the first run

1. Create the Hetzner project "Homelab - Public" and an API token with
   read/write access in it.
2. Create `secrets.env` here, SOPS-encrypted, holding the token:

   ```bash
   sops opentofu/resources/skylab/secrets.env   # HCLOUD_TOKEN=<token>
   ```

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
| `HCLOUD_TOKEN` (environment, not a variable) | `secrets.env` |
