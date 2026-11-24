"""Checks every committed dashboard. Run from this directory: python3 -m unittest test_dashboards"""
import glob
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = sorted(glob.glob(os.path.join(HERE, "*", "*.json")))


def panels(nodes):
    for p in nodes:
        yield p
        yield from panels(p.get("panels", []))


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


if __name__ == "__main__":
    unittest.main()
