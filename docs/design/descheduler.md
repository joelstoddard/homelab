# Descheduler

Kubernetes moves a pod only when its node fails. A node that stays `Ready`
but cannot run containers — a power-cut VM whose runtime returns
`exec format error` for every freshly unpacked image until its EPHEMERAL
partition is wiped — keeps a pod in `CrashLoopBackOff` indefinitely. Pods
that end `Failed` (evicted, `ContainerStatusUnknown`, a lost leader election)
stay as objects until someone deletes them, and appear in every "not
Running" sweep. The `descheduler/` layer handles both: it evicts the pod
through the eviction API, and the pod's controller makes a replacement.

## Design

The upstream chart, pinned in `descheduler/app/helmrelease.yaml`, runs as a
one-replica Deployment that makes a pass every 5 minutes. A Deployment rather
than the chart's default CronJob, because the resident pod serves metrics
that Alloy can scrape; a CronJob pod lives for seconds.

The policy enables only the `deschedule` extension point, with two plugins:

1. `RemovePodsHavingTooManyRestarts`, at 5 restarts, init containers
   included, and only for a pod whose container is in `CrashLoopBackOff` at
   the time of the pass. The kubelet's back-off (10 s, doubling) puts the
   fifth restart about 5 minutes after the first crash, so a stuck pod moves
   5–10 minutes after it starts failing.
2. `RemoveFailedPods`, for a pod that is at least an hour old, which leaves
   time to read a failure before the object goes. Pods owned by a `Job` are
   excluded: they hold the logs of a failed CronJob run, and the Job
   controller owns their history (`failedJobsHistoryLimit`).

`DefaultEvictor` protections differ from the chart's defaults:

1. `SystemCriticalPods` is off, so a dead `cilium-operator` replica in
   `kube-system` is collected. This is safe only because both plugins touch
   pods that already do not work.
2. `PodsWithPVC` is off, so a crash-looping app on a Longhorn claim moves
   too; its volume reattaches on the new node.
3. `PodsWithLocalStorage` is off, as in the chart.
4. `DaemonSetPods` stays on: the DaemonSet controller puts the pod straight
   back on the same node, and replaces its own Failed pods.

## Limits

1. Eviction does not mark the node bad. The scheduler may place the
   replacement on the same broken node, which already holds the image. Only
   node remediation (cordon, EPHEMERAL wipe) closes that.
2. A pod that crash-loops because of its own bug, not its node's, is evicted
   every few passes for as long as the bug lasts. The restart counter resets
   with each new pod, so this costs one eviction per 5–10 minutes.
3. A single-replica `Recreate` Deployment is down between eviction and the
   new pod's start — it was down already.

## No rebalancing

The chart's default profile also enables `RemoveDuplicates`,
`LowNodeUtilization`, `RemovePodsViolatingTopologySpreadConstraint` and the
affinity and taint plugins. They evict healthy pods to spread load. Here
that means Longhorn reattachments and restarts of single-replica apps, for a
cluster whose placement is already set by zones and anti-affinity. None is
enabled; the profile list in `values.yaml` replaces the chart's.

## The state filter

`states: [CrashLoopBackOff]` is load-bearing. Restart counts never reset
for the life of a pod, and many healthy pods carry hundreds from past node
failures. Without the filter, every one of them is a target on the first
pass. A chart bump that drops or renames the argument fails open in exactly
this way.

## Metrics

`/metrics` is HTTPS on `:10258` with a self-signed certificate and no
authentication. The annotated-pod scrape has no TLS settings, so
`alloy/app/config/cluster.alloy` has an explicit `descheduler` job with
`insecure_skip_verify`. `descheduler_pods_evicted_total` counts evictions by
`result`, `strategy`, `namespace` and `node`, where `namespace` and `node`
are the evicted pod's. The job sets `honor_labels` so those two win over the
scrape target's own labels instead of arriving as `exported_namespace` and
`exported_node`.

## Verifying

Before a chart bump, render it and read the policy ConfigMap:

```bash
helm template d descheduler --repo https://kubernetes-sigs.github.io/descheduler/ \
  --version <new> -f kubernetes/clusters/homelab/descheduler/app/values.yaml
```

It must contain `states: [CrashLoopBackOff]`, `excludeOwnerKinds: [Job]`,
and no `balance` plugins. Then list what the policy would target now; the
answer should be only pods that do not work:

```bash
kubectl get pods -A | grep -E 'CrashLoopBackOff|Error|Evicted|ContainerStatusUnknown'
```
