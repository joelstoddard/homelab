"""Tests for the annotate callback. Run: python -m unittest discover -s ansible/plugins/tests

The callback marks a play that changed something as an Operator annotation; why:
docs/design/observability.md, "Change annotations".
"""
import json
import os
import stat
import tempfile
import unittest

from ansible.plugins.loader import callback_loader, init_plugin_loader

PLUGINS = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

init_plugin_loader()
callback_loader.add_directory(os.path.join(PLUGINS, "callback"))
annotate = callback_loader.get("annotate", class_only=True)
module = __import__(annotate.__module__, fromlist=["describe"])


def host(changed=0, failures=0, unreachable=0):
    return {"ok": 1, "changed": changed, "failures": failures, "unreachable": unreachable,
            "skipped": 0, "rescued": 0, "ignored": 0}


class Describe(unittest.TestCase):
    def test_a_run_that_changed_nothing_leaves_no_mark(self):
        self.assertIsNone(module.describe("upgrade.yaml", {"a": host(), "b": host()}, check=False))

    def test_a_check_run_leaves_no_mark_even_with_changes(self):
        self.assertIsNone(module.describe("upgrade.yaml", {"a": host(changed=3)}, check=True))

    def test_a_failure_without_a_change_leaves_no_mark(self):
        self.assertIsNone(module.describe("dns.yaml", {"a": host(failures=1)}, check=False))

    def test_a_change_names_the_playbook_the_count_and_the_changed_hosts(self):
        text = module.describe("dns.yaml", {"pihole-02": host(changed=2), "bind9-01": host(changed=1),
                                            "lancache-01": host()}, check=False)
        self.assertEqual(text, "ansible: dns.yaml changed 3 tasks on bind9-01, pihole-02")

    def test_a_change_with_failures_says_so(self):
        text = module.describe("main.yaml", {"rumba": host(changed=1), "tango": host(failures=2, unreachable=1)},
                               check=False)
        self.assertEqual(text, "ansible: main.yaml changed 1 task on rumba; failed on tango")


class Posting(unittest.TestCase):
    """The stats hook calls the annotate script with a region, and never raises."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.record = os.path.join(self.tmp, "record.json")
        self.fake = os.path.join(self.tmp, "annotate")
        with open(self.fake, "w") as f:
            f.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                    f"json.dump({{'argv': sys.argv[1:], 'start': os.environ.get('ANNOTATE_START_MS'), "
                    f"'end': os.environ.get('ANNOTATE_END_MS')}}, open({self.record!r}, 'w'))\n")
        os.chmod(self.fake, stat.S_IRWXU)

    def run_stats(self, summary, check=False, script=None):
        cb = annotate()
        cb.set_options()
        cb.script = script or self.fake
        cb.check = check
        cb.playbook = "upgrade.yaml"
        cb.start_ms = 1_700_000_000_000
        cb.post(summary)

    def test_posts_a_region_tagged_ansible_and_the_playbook(self):
        self.run_stats({"k8s-server-01": host(changed=1)})
        with open(self.record) as f:
            got = json.load(f)
        self.assertEqual(got["argv"][:2], ["ansible", "ansible: upgrade.yaml changed 1 task on k8s-server-01"])
        self.assertIn("playbook:upgrade.yaml", got["argv"][2:])
        self.assertEqual(got["start"], "1700000000000")
        self.assertGreater(int(got["end"]), int(got["start"]))

    def test_a_failed_run_is_tagged_failed(self):
        self.run_stats({"a": host(changed=1), "b": host(failures=1)})
        with open(self.record) as f:
            self.assertIn("failed", json.load(f)["argv"][2:])

    def test_posts_nothing_for_a_check_run(self):
        self.run_stats({"a": host(changed=1)}, check=True)
        self.assertFalse(os.path.exists(self.record))

    def test_a_missing_script_does_not_raise(self):
        self.run_stats({"a": host(changed=1)}, script=os.path.join(self.tmp, "absent"))


if __name__ == "__main__":
    unittest.main()
