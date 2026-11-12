# Media stack one-shot Jobs

One-shot `Job` manifests for the `media` namespace. None of this is applied by
Flux — `Job` specs are immutable, so a later edit would make Flux fail its apply
with a field-is-immutable error, and no kustomization references this directory.

Run them by hand from the repo root. Background: `docs/design/media-foundation.md`.

## Create the downloads tree

`/mnt/Voyager/public/downloads/{complete,incomplete}/{qbittorrent,sabnzbd}` must
exist before any download client mounts a volume over it — mounting a
subdirectory that does not exist fails the pod.

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

## Jellyfin's config volume

Migrated out of the old `jellyfin` namespace on 2026-09-19, verified, and cut
over; the staging manifests have been removed along with that layer.

The method and the measured results are recorded in `docs/design/jellyfin.md`
under "The cutover from the standalone layer, as performed".
