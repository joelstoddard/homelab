# Media stack migration runbook

One-shot Jobs (and, for the config copy, a staging PV/PVC) that move Jellyfin
into the `media` namespace's shared library. None of this is applied by Flux —
`Job` specs are immutable, so a later edit would make Flux fail its apply with
a field-is-immutable error, and no kustomization references this directory.
Run each command below by hand, in order, from the repo root. Background:
`docs/design/arr-stack.md`.

## 1. Create the downloads tree

Runs once `media-library` exists (post-merge of the PR that created it). Not
tied to the Jellyfin cutover — safe to run any time after that.

```bash
kubectl --context homelab apply -f kubernetes/media/migration/create-downloads-tree.yaml
kubectl --context homelab -n media wait --for=condition=complete job/create-downloads-tree --timeout=120s
kubectl --context homelab -n media logs job/create-downloads-tree
```

Expected: the wait returns `condition met`, and the logs list both
`qbittorrent` and `sabnzbd` under each of `complete` and `incomplete`.

Clean up:

```bash
kubectl --context homelab -n media delete job create-downloads-tree
```

## 2. Suspend the old layer, then stop Jellyfin

**This is the only step with downtime.** Suspend the Flux Kustomization
*before* scaling down — Flux re-applies its manifests every 10 minutes and
would otherwise revert the scale.

The two Jellyfins must never run at the same time, for two independent
reasons. First, the copy needs a quiescent SQLite database — copying it while
live risks a torn copy. Second, `kubernetes/jellyfin/app/pv.yaml` still
specifies `soft` while `media-library` specifies `hard`; NFS mount options are
superblock properties shared per client, server and export, so if both pods
land on the same node, whichever mounts first sets policy for the other.

```bash
flux suspend kustomization jellyfin
kubectl --context homelab -n jellyfin scale deploy/jellyfin --replicas=0
kubectl --context homelab -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=120s
```

`rollout status` returns as soon as the Deployment's spec is satisfied, which
for zero replicas is immediately — it does not wait for the old pod to
actually terminate, so `wait --for=delete` is used instead.

```bash
kubectl --context homelab -n jellyfin get pods
```

Expected: only `jellyfin-exporter` remains (it will log connection errors —
harmless).

## 3. Stage out the config volume

`stage-out-jellyfin-config.yaml` contains a literal `${VOYAGER_IP}` that is
**not** substituted by Flux — this file is applied by hand, outside Flux's
`postBuild.substituteFrom`. Read the live address off the `media-library`
PersistentVolume and pipe it through `sed` at apply time; never write the
address into the file. If the lookup comes back empty, the rendered
`PersistentVolume` is invalid and rejected, but the `PersistentVolumeClaim`
and `Job` still apply and hang `Pending` forever — check for an empty value
before piping into `sed`.

```bash
VOYAGER_IP=$(kubectl --context homelab get pv media-library -o jsonpath='{.spec.nfs.server}')
[ -n "$VOYAGER_IP" ] || { echo "VOYAGER_IP is empty, stop" >&2; exit 1; }
sed "s|\${VOYAGER_IP}|$VOYAGER_IP|" \
  kubernetes/media/migration/stage-out-jellyfin-config.yaml \
  | kubectl --context homelab apply -f -
kubectl --context homelab -n jellyfin wait --for=condition=complete \
  job/stage-out-jellyfin-config --timeout=1800s
kubectl --context homelab -n jellyfin logs job/stage-out-jellyfin-config
```

The `wait` blocks for the full 1800s if the Job has already failed rather than
returning early. If it seems stalled, check progress in another shell with
`kubectl --context homelab -n jellyfin get job stage-out-jellyfin-config`.

Expected: `SOURCE` and `STAGED` report the same size (about `4.5G`) as a human
sanity check — `du -sh` reports allocated blocks and can legitimately differ
slightly across filesystems, so it is not the gate. The gate is exact:
`SOURCE_DB` and `STAGED_DB` must report the same byte count (roughly
105000000), and `SOURCE_FILES` must equal `STAGED_FILES`. **If either exact
pair differs, stop — do not proceed to stage-in.**

The log also shows lines like `cp: can't preserve ownership of '...': Operation
not permitted` — expected, from the NFS export's mapall plus the container
running as a non-root UID, and harmless; `cp -a` still exits 0.

## 4. Stage in the config volume

Before applying, confirm the destination Deployment is really scaled down —
`cp -a` into a live SQLite database would corrupt it:

```bash
kubectl --context homelab -n media get deploy jellyfin -o jsonpath='{.spec.replicas}'
```

Must print `0` (PR-1 ships it that way; this only confirms nothing has since
changed it).

```bash
kubectl --context homelab apply -f kubernetes/media/migration/stage-in-jellyfin-config.yaml
kubectl --context homelab -n media wait --for=condition=complete \
  job/stage-in-jellyfin-config --timeout=1800s
kubectl --context homelab -n media logs job/stage-in-jellyfin-config
```

As in step 3, the `wait` blocks the full 1800s on a failed Job rather than
returning early — check `kubectl --context homelab -n media get job
stage-in-jellyfin-config` in another shell if it seems stalled. The log will
also show the same harmless `cp: can't preserve ownership` lines as step 3.

Expected: `STAGED` and `RESTORED` report the same size as a sanity check;
`STAGED_DB` must equal `RESTORED_DB` exactly (and match `SOURCE_DB` /
`STAGED_DB` from step 3), `STAGED_FILES` must equal `RESTORED_FILES`, and
`SETTINGS` reports a non-zero file count. **If any exact pair differs, stop —
do not cut over the new Jellyfin.**

## 5. Cut over and verify

Suspend the `media` Kustomization first, for the same reason as step 2 —
otherwise Flux reverts the scale within its reconcile interval:

```bash
flux suspend kustomization media
kubectl --context homelab -n media scale deploy/jellyfin --replicas=1
```

Confirm it serves the restored library and watch history on the temporary
verification hostname, `jellyfin-new.${DOMAIN}` (kept distinct from the
production hostname so two `IngressRoute`s never race for the same `Host()`
match).

## 6. Roll back to serving and clean up

Once verified, put the cluster back into a steady, fully-reconciling state
before doing anything else — this migration does not itself cut the
production hostname over:

```bash
kubectl --context homelab -n media scale deploy/jellyfin --replicas=0
flux resume kustomization media
flux resume kustomization jellyfin
kubectl --context homelab -n jellyfin scale deploy/jellyfin --replicas=1
```

The old `jellyfin` namespace resumes serving production traffic. A later PR
sets the `media` layer's Jellyfin to `replicas: 1` with the real hostname and
deletes `kubernetes/jellyfin/` — not this one. **Do not delete
`kubernetes/jellyfin/` before then**: its `jellyfin-config` PVC is the only
intact copy of the database until that PR's cutover is verified, and
Longhorn's reclaim policy on it is `Delete` — pruning the namespace takes the
PVC with it.

Then remove the migration scaffolding, now that both Kustomizations are
reconciling again and the copies are verified:

```bash
kubectl --context homelab -n jellyfin delete job stage-out-jellyfin-config
kubectl --context homelab -n media delete job stage-in-jellyfin-config
kubectl --context homelab -n jellyfin delete pvc jellyfin-migration-staging
kubectl --context homelab delete pv jellyfin-migration-staging
```

Then remove the staging directory from the NAS (about 4.5 GiB):
`/mnt/Voyager/public/.jellyfin-migration`.

These are deliberately left in place until this point — they are the rollback
path if verification in step 5 fails.
