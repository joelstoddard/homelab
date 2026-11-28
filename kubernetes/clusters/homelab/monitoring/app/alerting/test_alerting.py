"""Checks the provisioned alert rules and policy. Run from this directory: python3 -m unittest test_alerting"""
import glob
import os
import re
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
RULE_FILES = sorted(glob.glob(os.path.join(HERE, "rules-*.yaml")))

EXPECTED_UIDS = {
    "infra-target-down",
    "infra-probe-failing",
    "infra-ingestion-stopped",
    "infra-prom-size-retention",
    "infra-alloy-remote-write",
    "infra-loki-write-dropped",
    "infra-container-restarts",
    "infra-pod-oom-killed",
    "infra-etcd-rss",
    "infra-flux-not-ready",
    "infra-node-not-ready",
    "infra-node-cpu-high",
    "infra-node-memory-high",
    "infra-zram-high",
    "infra-host-oom-kill",
    "infra-node-requests-high",
    "infra-pvc-full",
    "infra-longhorn-degraded",
    "infra-smart-failing",
    "infra-cert-expiry",
    "infra-container-memory-near-limit",
    "infra-container-cpu-near-limit",
    "infra-latency-p95",
    "infra-latency-p50",
    "infra-recyclarr-sync-failed",
    "infra-recyclarr-no-sync",
    "infra-nuc-temperature",
    "infra-pi-temperature",
    "infra-node-disk-full",
    "infra-truenas-pool-warning",
    "infra-truenas-pool-critical",
}


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def rules():
    for path in RULE_FILES:
        for group in load(path)["groups"]:
            yield from group["rules"]


def rule(uid):
    return next(r for r in rules() if r["uid"] == uid)


SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}
# increase() only: a rate() rule here alerts on a level sustained for its for:, which is the intent.
COUNTER_RANGE = re.compile(r"\bincrease\([^\[]*\[(\d+)([smhd])\]")


def seconds(duration):
    return int(duration[:-1]) * SECONDS[duration[-1]]


class Rules(unittest.TestCase):
    def test_rule_uids_unique_and_expected(self):
        uids = [r["uid"] for r in rules()]
        self.assertEqual(len(uids), len(set(uids)), uids)
        self.assertEqual(set(uids), EXPECTED_UIDS)

    def test_every_query_uses_a_fixed_datasource_uid(self):
        for r in rules():
            for query in r["data"]:
                self.assertIn(query["datasourceUid"], {"prometheus", "loki", "__expr__"}, f"{r['uid']} {query['refId']}")

    def test_every_condition_names_a_query(self):
        # A condition naming a missing refId is accepted by YAML and rejected by Grafana at load.
        for r in rules():
            self.assertIn(r["condition"], {q["refId"] for q in r["data"]}, r["uid"])

    def test_for_is_shorter_than_every_counter_window(self):
        # A one-off counter step stays in the window for less than the window, so a for: at least
        # that long never sees the condition hold and the rule cannot fire.
        checked = 0
        for r in rules():
            for amount, unit in COUNTER_RANGE.findall(r["data"][0]["model"]["expr"]):
                checked += 1
                self.assertLess(seconds(r["for"]), int(amount) * SECONDS[unit], r["uid"])
        self.assertTrue(checked)

    def test_restart_rule_groups_by_object_labels(self):
        # kube-state-metrics keeps the restarting pod's own namespace/pod labels (honor_labels);
        # grouping on exported_* matches no series, so the rule could never fire.
        expr = rule("infra-container-restarts")["data"][0]["model"]["expr"]
        self.assertIn("sum by (namespace, pod)", expr)
        self.assertNotIn("exported_", expr)

    def test_ingestion_rule_alerts_on_nodata(self):
        # A stopped Prometheus returns nothing; any other no-data state stays silent through the outage.
        r = rule("infra-ingestion-stopped")
        self.assertEqual(r["noDataState"], "Alerting")
        self.assertEqual(r["execErrState"], "Alerting")


    def test_recyclarr_no_sync_rule_alerts_on_nodata(self):
        # A server that never syncs writes no completion line, so the query returns nothing.
        r = rule("infra-recyclarr-no-sync")
        self.assertEqual(r["noDataState"], "Alerting")
        self.assertIn('completed with status Succeeded', r["data"][0]["model"]["expr"])

    def test_temperature_rules_split_the_hosts(self):
        # A NUC throttles at 100 °C and a Pi at 80 °C; one shared threshold either never
        # fires for the NUCs or always fires for the Pis.
        nuc = rule("infra-nuc-temperature")["data"][0]["model"]["expr"]
        pi = rule("infra-pi-temperature")["data"][0]["model"]["expr"]
        self.assertIn('instance=~"rumba|tango|salsa|samba"', nuc)
        self.assertIn('instance!~"rumba|tango|salsa|samba"', pi)

    def test_pool_rules_share_one_expression_at_rising_thresholds(self):
        # Two copies of the pool formula can drift apart; the levels must stay 80 % then 90 %.
        warn, crit = rule("infra-truenas-pool-warning"), rule("infra-truenas-pool-critical")
        self.assertEqual(warn["data"][0]["model"]["expr"], crit["data"][0]["model"]["expr"])
        level = lambda r: r["data"][2]["model"]["conditions"][0]["evaluator"]["params"][0]
        self.assertEqual((level(warn), level(crit)), (0.8, 0.9))

    def test_probe_rule_reads_probe_success(self):
        # A failed blackbox probe still scrapes with up == 1; only probe_success carries the result.
        expr = rule("infra-probe-failing")["data"][0]["model"]["expr"]
        self.assertIn("probe_success", expr)
        self.assertNotIn("up", expr.replace("probe_success", ""))


class Wiring(unittest.TestCase):
    def setUp(self):
        self.kustomization = load(os.path.join(HERE, "kustomization.yaml"))

    def test_every_rules_file_is_generated(self):
        # The sidecar loads only generated ConfigMaps, so an unwired file never reaches Grafana.
        generated = {entry.split("=")[-1] for g in self.kustomization["configMapGenerator"] for entry in g["files"]}
        self.assertTrue(RULE_FILES)
        for path in RULE_FILES:
            self.assertIn(os.path.basename(path), generated)

    def test_kustomization_disables_substitution_and_labels(self):
        # Flux's envsubst would blank every {{ $labels.x }} in the annotations.
        options = self.kustomization["generatorOptions"]
        self.assertEqual(options["annotations"]["kustomize.toolkit.fluxcd.io/substitute"], "disabled")
        self.assertEqual(options["labels"]["grafana_alert"], "1")
        self.assertTrue(options["disableNameSuffixHash"])

    def test_policy_routes_to_ntfy(self):
        policies = load(os.path.join(HERE, "policy.yaml"))["policies"]
        self.assertEqual([p["receiver"] for p in policies], ["ntfy"])

    def test_contact_point_secret_is_encrypted_and_labelled(self):
        # The sidecar finds the Secret by its plaintext label; generatorOptions never reach a resource,
        # so the label and the substitute opt-out sit on the Secret itself.
        name = "secret-contact-point.sops.yaml"
        self.assertIn(name, self.kustomization["resources"])
        secret = load(os.path.join(HERE, name))
        self.assertIn("sops", secret)
        self.assertTrue(secret["stringData"])
        for value in secret["stringData"].values():
            self.assertTrue(value.startswith("ENC["), "stringData must be encrypted")
        metadata = secret["metadata"]
        self.assertEqual(metadata["labels"]["grafana_alert"], "1")
        self.assertEqual(metadata["annotations"]["kustomize.toolkit.fluxcd.io/substitute"], "disabled")


if __name__ == "__main__":
    unittest.main()
