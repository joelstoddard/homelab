"""Checks every committed dashboard. Run from this directory: python3 -m unittest test_dashboards"""
import glob
import json
import os
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


if __name__ == "__main__":
    unittest.main()
