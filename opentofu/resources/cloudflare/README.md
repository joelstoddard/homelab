# resources/cloudflare/

Declares skylab's Cloudflare Tunnel, its ingress routes, the token
cloudflared runs with, and one proxied DNS record per public hostname. The
design is in `docs/design/skylab-ingress.md`; the order of the steps is in
`docs/skylab-cutover.md`.

No gate: the tunnel is free and sits idle until cloudflared connects, so the
default `make -C opentofu` loop runs this directory. The DNS-only `turn`
record is in `../skylab/`, because it points at skylab's primary IP and
exists only while skylab does.

## Hostnames

`hostnames.tf` lists every name: a route to its in-cluster Service and a
proxied record each. The apex, `www` and `chat` are imported from the live
zones while they still point at Ashburn (`ashburn.tf`), so they stay A
records with the Ashburn address. `next` and `metachat-next` are the cutover
gate's test names and are tunnel CNAMEs from the start.

## Before the first run

1. Create an API token with Account › Cloudflare Tunnel › Edit and
   Zone › DNS › Edit, on the two app zones. The LAN domain's zone joins
   when Forgejo's `_acme-challenge` CNAME lands here
   (`docs/design/skylab-forgejo.md`, "Name and certificate").
2. Find the three live records' IDs: Cloudflare's
   `GET /zones/<zone_id>/dns_records?name=<fqdn>` returns each one's `id`.
3. Create `secrets.env` here, SOPS-encrypted:

   ```bash
   sops opentofu/resources/cloudflare/secrets.env
   ```

   | Line | Holds |
   |---|---|
   | `CLOUDFLARE_API_TOKEN` | The token from step 1; the provider reads it natively |
   | `TF_VAR_account_id` | The account ID that owns the tunnel |
   | `TF_VAR_joelst_zone`, `TF_VAR_joelst_zone_id` | joelst's zone (`example.com`) and its zone ID |
   | `TF_VAR_metachat_zone`, `TF_VAR_metachat_zone_id` | metachat's zone (`example.net`) and its zone ID |
   | `TF_VAR_ashburn_ipv4` | Ashburn's IPv4, the live records' content |
   | `TF_VAR_ashburn_record_ids` | `'{"joelst":"<id>","joelst-www":"<id>","metachat":"<id>"}'`: the record IDs from step 2, keyed by `hostnames.tf` key |

   The Makefile refuses every run that includes this directory until the
   file exists, because the provider does not configure without a token.

## Running it

```bash
make -C opentofu check LIMIT=cloudflare
make -C opentofu apply LIMIT=cloudflare
```

The first plan imports the three live records. Its only allowed change to
them is an in-place `comment` → `opentofu`, which has no effect on DNS. A
planned change to `type`, `content`, `proxied` or `ttl` means a variable is
wrong: stop.

## The tunnel token

Once, after the first apply, from the repo root on the branch that adds the
`cloudflared` layer:

```bash
TF_ENCRYPTION="$(opentofu/scripts/build-tf-encryption.sh)" \
  tofu -chdir=opentofu/resources/cloudflare output -raw tunnel_token \
  | kubectl create secret generic cloudflared-token --namespace cloudflared \
      --from-file=token=/dev/stdin --dry-run=client --output yaml \
  | sops encrypt --filename-override kubernetes/clusters/skylab/cloudflared/app/secret.sops.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > kubernetes/clusters/skylab/cloudflared/app/secret.sops.yaml
```

The Secret is `cloudflared-token`, key `token`, which cloudflared reads with
`--token-file`. Nothing prints the value. Repeat it only after refreshing the
token.

## The cutover PR

1. Delete `ashburn.tf`.
2. In `hostnames.tf`, delete the `joelst-next` and `metachat-next` entries,
   and set `type = "CNAME"` and `content = local.tunnel_cname`.
3. Remove `TF_VAR_ashburn_ipv4` and `TF_VAR_ashburn_record_ids` from
   `secrets.env`.

The plan replaces the three records (a type change cannot be made in place)
and destroys the two test records and their routes. Rollback is a revert of
the PR, which recreates the A records; an import is not needed again.
