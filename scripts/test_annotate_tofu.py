"""Tests for scripts/annotate-tofu. Run: python3 -m unittest discover -s scripts

annotate-tofu turns an OpenTofu apply log into an Operator annotation only when the root
changed something; why: docs/design/observability.md, "Change annotations".
"""
import json
import os
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "annotate-tofu")


class AnnotateTofu(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.record = os.path.join(self.tmp, "record.json")
        self.fake = os.path.join(self.tmp, "annotate")
        with open(self.fake, "w") as f:
            f.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                    f"json.dump({{'argv': sys.argv[1:], 'start': os.environ.get('ANNOTATE_START_MS')}}, "
                    f"open({self.record!r}, 'w'))\n")
        os.chmod(self.fake, stat.S_IRWXU)

    def run_with_log(self, text, root="resources/rumba"):
        log = os.path.join(self.tmp, "apply.log")
        with open(log, "w") as f:
            f.write(text)
        return subprocess.run([SCRIPT, root, log, "1700000000000"], env=dict(os.environ, ANNOTATE=self.fake),
                              capture_output=True, text=True)

    def posted(self):
        if not os.path.exists(self.record):
            return None
        with open(self.record) as f:
            return json.load(f)

    def test_a_root_that_changed_is_marked_with_its_counts(self):
        self.run_with_log("...\nApply complete! Resources: 1 added, 2 changed, 0 destroyed.\n")
        got = self.posted()
        self.assertEqual(got["argv"][:2], ["tofu", "tofu: resources/rumba 1 added, 2 changed, 0 destroyed"])
        self.assertIn("root:rumba", got["argv"][2:])
        self.assertEqual(got["start"], "1700000000000")

    def test_a_no_op_apply_leaves_no_mark(self):
        self.run_with_log("No changes. Your infrastructure matches the configuration.\n"
                          "Apply complete! Resources: 0 added, 0 changed, 0 destroyed.\n")
        self.assertIsNone(self.posted())

    def test_the_last_apply_counts_after_a_retry(self):
        # run_tofu re-applies once on the provider's inconsistent-plan error and appends to the log.
        self.run_with_log("Error: Provider produced inconsistent final plan\n"
                          "Apply complete! Resources: 0 added, 0 changed, 0 destroyed.\n"
                          "Apply complete! Resources: 0 added, 3 changed, 0 destroyed.\n")
        self.assertEqual(self.posted()["argv"][1], "tofu: resources/rumba 0 added, 3 changed, 0 destroyed")

    def test_a_log_without_an_apply_line_leaves_no_mark_and_succeeds(self):
        result = self.run_with_log("Error: something else\n")
        self.assertIsNone(self.posted())
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
