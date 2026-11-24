"""Tests for hosts.py. Run from this directory: python3 -m unittest test_hosts"""
import json
import os
import re
import unittest

from hosts import HOSTS_DIR, TEMPLATE, FEATURES, dump, render

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path):
    with open(os.path.join(HERE, path)) as f:
        return json.load(f)


class Render(unittest.TestCase):
    def test_substitutes_host_in_nested_strings(self):
        d = render({"panels": [{"targets": [{"expr": 'up{instance="__HOST__"}'}]}]}, "rumba", {})
        self.assertEqual(d["panels"][0]["targets"][0]["expr"], 'up{instance="rumba"}')

    def test_sets_uid_and_title(self):
        d = render({"uid": "x", "title": "x", "panels": []}, "salsa", {})
        self.assertEqual((d["uid"], d["title"]), ("homelab-host-salsa", "Salsa"))

    def test_drops_panels_whose_feature_is_off_and_strips_the_marker(self):
        t = {"panels": [{"id": 1}, {"id": 2, "homelabRequires": "fans"}, {"id": 3, "homelabRequires": "power"}]}
        d = render(t, "rumba", {"fans": False, "power": True})
        self.assertEqual(d["panels"], [{"id": 1}, {"id": 3}])

    def test_drops_marked_panels_nested_in_a_row(self):
        t = {"panels": [{"type": "row", "panels": [{"id": 1}, {"id": 2, "homelabRequires": "fans"}]}]}
        d = render(t, "rumba", {"fans": False})
        self.assertEqual(d["panels"][0]["panels"], [{"id": 1}])

    def test_string_settings_fill_their_placeholders(self):
        t = {"panels": [{"targets": [{"expr": 'x{mountpoint="__ROOTFS__"} {__LOGS__}'}]}]}
        d = render(t, "kosmos", {"rootfs": "/var", "logs": 'job="talos", node="kosmos"', "fans": False})
        self.assertEqual(d["panels"][0]["targets"][0]["expr"], 'x{mountpoint="/var"} {job="talos", node="kosmos"}')

    def test_keeps_unless_panels_only_when_their_flag_is_off_and_strips_the_marker(self):
        t = {"panels": [{"id": 1, "homelabRequires": "power"}, {"id": 2, "homelabUnless": "power"}]}
        self.assertEqual(render(t, "kosmos", {"power": False})["panels"], [{"id": 2}])
        self.assertEqual(render(t, "rumba", {"power": True})["panels"], [{"id": 1}])

    def test_unknown_feature_fails(self):
        with self.assertRaises(KeyError):
            render({"panels": [{"homelabRequires": "gpu"}]}, "rumba", {"fans": True})

    def test_does_not_mutate_the_template(self):
        t = {"panels": [{"id": 2, "homelabRequires": "fans", "title": "__HOST__"}]}
        render(t, "rumba", {"fans": True})
        self.assertEqual(t, {"panels": [{"id": 2, "homelabRequires": "fans", "title": "__HOST__"}]})


class Committed(unittest.TestCase):
    def test_generated_files_are_current(self):
        template, features = load(TEMPLATE), load(FEATURES)
        for host, flags in features.items():
            with open(os.path.join(HERE, HOSTS_DIR, f"{host}.json")) as f:
                self.assertEqual(f.read(), dump(render(template, host, flags)),
                                 f"{host}.json is stale: run python3 hosts.py")


class Template(unittest.TestCase):
    def test_no_hard_coded_device_names(self):
        exprs = re.findall(r'"expr": "((?:[^"\\]|\\.)*)"', json.dumps(load(TEMPLATE)))
        self.assertTrue(exprs)
        for e in exprs:
            self.assertIsNone(re.search(r'device=~?\\"(nvme\d|enp|eno|vmbr\d)', e), e)


if __name__ == "__main__":
    unittest.main()
