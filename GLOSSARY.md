# Homelab

The language of this homelab's infrastructure: the machines, the clusters they form, and how workloads are placed on them.

## Language

**Home cluster**:
The Kubernetes cluster on the home LAN: the NUC VMs and the Pis.
_Avoid_: main cluster, LAN cluster

**Public cluster**:
A Kubernetes cluster on the public internet with no route to the home LAN, running only the workloads placed on it deliberately. Skylab is the first.
_Avoid_: public node, edge cluster, cloud cluster, VPS cluster

**Cutover**:
The single switch from the old skylab to the rebuilt one: DNS moves, the old server shuts down.
_Avoid_: migration day, go-live
