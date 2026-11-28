"""Checks every committed dashboard. Run from this directory: python3 -m unittest test_dashboards"""
import glob
import json
import os
import re
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = sorted(
    f for f in glob.glob(os.path.join(HERE, "**", "*.json"), recursive=True)
    if os.path.relpath(f, HERE).split(os.sep)[0] != "templates"
)


def panels(nodes):
    for p in nodes:
        yield p
        yield from panels(p.get("panels", []))


class Folders(unittest.TestCase):
    def test_every_file_has_one_generator_in_its_folder(self):
        # The sidecar builds folders from the annotation, so a file in another directory than its
        # annotation would land in a folder the tree does not show.
        with open(os.path.join(HERE, "kustomization.yaml")) as f:
            generators = yaml.safe_load(f)["configMapGenerator"]
        folders = {}
        for g in generators:
            for entry in g["files"]:
                path = entry.split("=")[-1]
                folders.setdefault(path, []).append(g["options"]["annotations"]["grafana_folder"])
        for path in FILES:
            rel = os.path.relpath(path, HERE)
            self.assertEqual(folders.get(rel), [os.path.dirname(rel)], rel)
        self.assertEqual(set(folders), {os.path.relpath(p, HERE) for p in FILES})

    def test_no_alloy_title_prefix(self):
        # The Alloy folder names the product; the prefix repeats it in every title.
        for path in FILES:
            with open(path) as f:
                title = json.load(f).get("title", "")
            self.assertFalse(title.startswith("Alloy / "), f"{os.path.relpath(path, HERE)}: {title}")

    def test_every_title_is_unique(self):
        # Grafana lists dashboards by title; a vendored copy with its replacement's title is indistinguishable.
        seen = {}
        for path in FILES:
            with open(path) as f:
                title = json.load(f).get("title", "")
            seen.setdefault(title, []).append(os.path.relpath(path, HERE))
        duplicates = {t: p for t, p in seen.items() if len(p) > 1}
        self.assertEqual(duplicates, {})

    def test_every_uid_is_unique(self):
        seen = {}
        for path in FILES:
            with open(path) as f:
                uid = json.load(f).get("uid")
            seen.setdefault(uid, []).append(os.path.relpath(path, HERE))
        duplicates = {u: p for u, p in seen.items() if len(p) > 1}
        self.assertEqual(duplicates, {})


class Layout(unittest.TestCase):
    def test_every_panel_position_is_whole_numbers(self):
        # Valid JSON with a list in gridPos passes lint and Flux but breaks Grafana's layout.
        self.assertTrue(FILES)
        for path in FILES:
            with open(path) as f:
                dashboard = json.load(f)
            for p in panels(dashboard.get("panels", [])):
                for key in ("h", "w", "x", "y"):
                    value = p.get("gridPos", {}).get(key)
                    self.assertIsInstance(value, int, f"{os.path.relpath(path, HERE)} panel {p.get('id')} gridPos.{key}={value!r}")


def change_toggles(path):
    with open(path) as f:
        dashboard = json.load(f)
    return {a.get("name"): a for a in dashboard.get("annotations", {}).get("list", [])}


class Changes(unittest.TestCase):
    # One toggle per source of change, so each can be switched off alone (docs/design/observability.md).
    GRAFANA = {"type": "grafana", "uid": "-- Grafana --"}

    def assert_tag_toggle(self, name, tag):
        self.assertTrue(FILES)
        for path in FILES:
            toggle = change_toggles(path).get(name)
            where = os.path.relpath(path, HERE)
            self.assertIsNotNone(toggle, f"{where}: no {name} annotation")
            self.assertEqual(toggle["datasource"], self.GRAFANA, where)
            self.assertTrue(toggle["enable"], where)
            self.assertEqual(toggle["target"]["type"], "tags", where)
            self.assertEqual(toggle["target"]["tags"], [tag], where)

    def test_every_dashboard_shows_flux_changes(self):
        # Flux posts organization annotations tagged flux; a dashboard shows them only when it queries the tag.
        self.assert_tag_toggle("Flux", "flux")

    def test_every_dashboard_shows_operator_changes(self):
        # scripts/annotate tags every Ansible, OpenTofu and manual change operator.
        self.assert_tag_toggle("Operator", "operator")

    def test_every_dashboard_shows_proxmox_changes(self):
        # The proxmox-annotations CronJob tags Proxmox changes made outside OpenTofu.
        self.assert_tag_toggle("Proxmox", "proxmox")

    def test_every_dashboard_shows_every_netbox_change(self):
        # No objectTypes filter: a prefix or IP edit matters as much as a device edit.
        for path in FILES:
            toggles = change_toggles(path)
            where = os.path.relpath(path, HERE)
            self.assertNotIn("NetBox changes", toggles, f"{where}: the device-and-VM-only query is replaced by NetBox")
            netbox = toggles.get("NetBox")
            self.assertIsNotNone(netbox, f"{where}: no NetBox annotation")
            self.assertEqual(netbox["datasource"], {"type": "netboxlabs-netbox-datasource", "uid": "netbox"}, where)
            self.assertTrue(netbox["enable"], where)
            self.assertEqual(netbox["target"].get("queryType"), "annotations", where)
            self.assertNotIn("objectTypes", netbox["target"], where)


class Power(unittest.TestCase):
    def test_power_never_deltas_raw_joules(self):
        # RAPL energy counters wrap; delta() reads them as a gauge and goes negative at the wrap.
        # Watts come from rate() alone, so every RAPL formula has one form.
        with open(os.path.join(HERE, "Hosts", "power.json")) as f:
            dashboard = json.load(f)
        exprs = [t["expr"] for p in panels(dashboard["panels"]) for t in p.get("targets", []) if "expr" in t]
        self.assertTrue(any("node_rapl" in e for e in exprs))
        for e in exprs:
            self.assertNotRegex(e, r"(delta|increase)\(node_rapl")


def netbox_targets(panel):
    return [t for t in panel.get("targets", [])
            if isinstance(t, dict) and isinstance(t.get("datasource"), dict) and t["datasource"].get("uid") == "netbox"]


def netbox_join_tables():
    for path in FILES:
        with open(path) as f:
            dashboard = json.load(f)
        for p in panels(dashboard.get("panels", [])):
            nb = netbox_targets(p)
            if p.get("type") == "table" and nb and len(nb) < len(p.get("targets", [])):
                yield os.path.relpath(path, HERE), p


class NetBox(unittest.TestCase):
    # NetBox is the base of the audit dashboard's tables by design; everywhere else it only adds columns.
    AUDIT = "Hosts/netbox.json"
    IDENTIFIERS = {"ip", "name", "address"}

    def test_netbox_joins_keep_metric_rows(self):
        tables = list(netbox_join_tables())
        self.assertTrue(tables)
        for rel, p in tables:
            if rel == self.AUDIT:
                continue
            ids = [t["id"] for t in p.get("transformations", [])]
            where = f"{rel}: {p.get('title')}"
            joins = [t for t in p["transformations"] if t["id"] == "joinByField"]
            self.assertTrue(joins and all(j["options"].get("mode") == "outerTabular" for j in joins), where)
            later = p["transformations"][ids.index("joinByField"):]
            self.assertTrue(any(
                t["id"] == "filterByValue" and t["options"].get("type") == "exclude"
                and any(f["config"]["id"] == "isNull" for f in t["options"]["filters"])
                for t in later), where)

    def test_netbox_join_tables_run_every_query(self):
        # A panel-level datasource sends every target to it; the NetBox queries then never run.
        for rel, p in netbox_join_tables():
            where = f"{rel}: {p.get('title')}"
            self.assertIn(p.get("datasource", {"uid": "-- Mixed --"}).get("uid"), {"-- Mixed --"}, where)
            for t in p["targets"]:
                self.assertIsInstance(t.get("datasource"), dict, f"{where}: {t.get('refId')}")

    def test_netbox_join_strips_frame_names(self):
        # joinByField suffixes NetBox fields with the frame name ("role netbox_devices"), so renames miss them.
        for rel, p in netbox_join_tables():
            if rel == NetBox.AUDIT:
                continue
            ids = [t["id"] for t in p["transformations"]]
            last_join = len(ids) - 1 - ids[::-1].index("joinByField")
            self.assertEqual(ids[last_join + 1], "renameByRegex", f"{rel}: {p.get('title')}")

    def test_netbox_join_scopes_only_the_first_combine(self):
        # A merged or joined frame has no refId, so a refId filter on a later transformation skips it.
        for rel, p in netbox_join_tables():
            seen_combine = False
            for t in p["transformations"]:
                if seen_combine and t["id"] != "merge":
                    self.assertNotIn("filter", t, f"{rel}: {p.get('title')}: {t['id']}")
                if t["id"] in ("merge", "joinByField"):
                    seen_combine = True

    def test_netbox_join_filters_name_real_queries(self):
        # Grafana's query filter matches an explicit refId list; it does not apply a lookahead regex as written.
        for rel, p in netbox_join_tables():
            refs = {t["refId"] for t in p["targets"]}
            for t in p["transformations"]:
                if "filter" in t:
                    m = re.fullmatch(r"/\^\((?:\?:)?([\w|]+)\)\$/", t["filter"]["options"])
                    self.assertTrue(m and set(m.group(1).split("|")) <= refs, f"{rel}: {p.get('title')}: {t['filter']}")

    def test_netbox_join_row_filter_names_a_shown_column(self):
        # Before organize the metric field names are not stable; the filter keys on the renamed header.
        for rel, p in netbox_join_tables():
            if rel == NetBox.AUDIT:
                continue
            ids = [t["id"] for t in p["transformations"]]
            organize = p["transformations"][ids.index("organize")]["options"].get("renameByName", {})
            last = p["transformations"][-1]
            self.assertEqual(last["id"], "filterByValue", f"{rel}: {p.get('title')}")
            for f in last["options"]["filters"]:
                self.assertIn(f["fieldName"], organize.values(), f"{rel}: {p.get('title')}")

    def test_netbox_record_column_links_to_netbox(self):
        # The plugin links the record cell only when the query returns display_url.
        for path in FILES:
            rel = os.path.relpath(path, HERE)
            if rel == self.AUDIT:
                continue
            with open(path) as f:
                dashboard = json.load(f)
            for p in panels(dashboard.get("panels", [])):
                organize = [t["options"] for t in p.get("transformations", []) if t["id"] == "organize"]
                if not organize or "NetBox" not in organize[-1].get("renameByName", {}).values():
                    continue
                objects = [t for t in netbox_targets(p) if t.get("queryType") == "objects"]
                if not objects:
                    continue
                for t in objects:
                    self.assertIn("display_url", t["fields"], f"{rel}: {p.get('title')}")
                # Excluding display_url empties the link the plugin builds from it; hide it instead.
                self.assertFalse(organize[-1].get("excludeByName", {}).get("display_url"), f"{rel}: {p.get('title')}")
                hidden = [o for o in p.get("fieldConfig", {}).get("overrides", [])
                          if o["matcher"].get("options") == "display_url"
                          and {"id": "custom.hidden", "value": True} in o["properties"]]
                self.assertTrue(hidden, f"{rel}: {p.get('title')}")

    def test_netbox_join_keys_lowercase(self):
        for path in FILES:
            with open(path) as f:
                dashboard = json.load(f)
            for p in panels(dashboard.get("panels", [])):
                for t in netbox_targets(p):
                    for k in t.get("joinKeys", []):
                        if k["source"] != "address":
                            self.assertEqual(k.get("transform"), "lower", f"{os.path.relpath(path, HERE)}: {p.get('title')}")

    def test_netbox_columns_are_prefixed(self):
        # Tables carry their own Role, Model and Status columns; an unprefixed NetBox header would clash.
        for path in FILES:
            with open(path) as f:
                dashboard = json.load(f)
            for p in panels(dashboard.get("panels", [])):
                nb = netbox_targets(p)
                if not nb or len(nb) == len(p.get("targets", [])):
                    continue
                keys = {k[side] for t in nb for k in t.get("joinKeys", []) for side in ("source", "output")}
                fields = {f for t in nb for f in t.get("fields", []) + t.get("contextFields", [])}
                renames = {}
                for t in p.get("transformations", []):
                    if t["id"] == "organize":
                        renames.update(t["options"].get("renameByName", {}))
                for field in sorted(fields - keys - self.IDENTIFIERS):
                    if field in renames:
                        self.assertTrue(renames[field].startswith("NetBox"),
                                        f"{os.path.relpath(path, HERE)}: {p.get('title')}: {field} -> {renames[field]}")


if __name__ == "__main__":
    unittest.main()
