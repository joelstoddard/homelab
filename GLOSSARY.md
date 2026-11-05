# Homelab

The language of this homelab's infrastructure: the machines, the cluster they form, and how workloads are placed on them.

## Language

**Public node**:
A Kubernetes node on the public internet, outside the home LAN, that runs only the workloads placed on it deliberately. Skylab is the first.
_Avoid_: edge node, cloud node, VPS node

**Cutover**:
The single switch from the old skylab to the rebuilt one: DNS moves, the old server shuts down.
_Avoid_: migration day, go-live
