# Homelab

The language of this homelab's infrastructure: the machines, the cluster they form, and how workloads are placed on them.

## Language

**Public cluster**:
A Kubernetes cluster on the public internet, separate from the home cluster and with no route back to the LAN. Skylab is the first.
_Avoid_: public node, edge cluster, cloud node, VPS

**Cutover**:
The single switch from the old skylab to the rebuilt one: DNS moves, the old server shuts down.
_Avoid_: migration day, go-live
