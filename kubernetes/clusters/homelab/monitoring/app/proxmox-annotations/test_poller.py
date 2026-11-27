"""Tests for poller.py. Run: python3 -m unittest discover -s <this directory>

The poller turns Proxmox's journal lines into Grafana annotations; why:
docs/design/observability.md, "Change annotations".
"""
import unittest

import poller

TASK = ("<root@pam> starting task UPID:Rumba:003D2AB1:07F5EE15:6AEF798C:qmshutdown:201:root@pam:")
UPDATE = "<root@pam> update VM 201: -balloon 4000 -memory 5000"
TOFU = ("<root@pam!terraform> starting task UPID:Salsa:003500D0:07F77AC3:6AEF798C:vzdestroy:321:"
        "root@pam!terraform:")


class Parse(unittest.TestCase):
    def test_a_task_names_its_type_and_target(self):
        self.assertEqual(poller.parse(TASK, "rumba"),
                         {"node": "rumba", "user": "root@pam", "action": "qmshutdown",
                          "text": "proxmox rumba: root@pam qmshutdown 201"})

    def test_a_config_update_carries_its_keys(self):
        self.assertEqual(poller.parse(UPDATE, "salsa"),
                         {"node": "salsa", "user": "root@pam", "action": "update",
                          "text": "proxmox salsa: root@pam update VM 201: -balloon 4000 -memory 5000"})

    def test_a_container_update_is_a_change_too(self):
        self.assertEqual(poller.parse("<root@pam> update CT 311: -memory 512", "rumba")["action"], "update")

    def test_opentofu_changes_are_skipped(self):
        # OpenTofu applies already post an Operator annotation.
        self.assertIsNone(poller.parse(TOFU, "salsa"))
        self.assertIsNone(poller.parse("<root@pam!terraform> update VM 201: -balloon 4000", "salsa"))

    def test_the_daily_package_list_refresh_is_not_a_change(self):
        # pve-daily-update.service runs it on every NUC every day; it installs nothing.
        line = "<root@pam> starting task UPID:Rumba:0011A2B3:07F5EE15:6AEF798C:aptupdate::root@pam:"
        self.assertIsNone(poller.parse(line, "rumba"))

    def test_logins_and_task_ends_are_not_changes(self):
        self.assertIsNone(poller.parse("<root@pam> successful auth for user 'root@pam'", "rumba"))
        self.assertIsNone(poller.parse("<root@pam> end task UPID:Rumba:1:2:3:qmshutdown:201:root@pam: OK", "rumba"))

    def test_an_unknown_line_is_skipped(self):
        self.assertIsNone(poller.parse("something else entirely", "rumba"))


class Query(unittest.TestCase):
    def test_shell_changes_are_read_whatever_unit_logged_them(self):
        # pvesh and qm run the API handler in-process and log under the SSH session's scope,
        # not pvedaemon.service (seen 2026-11-27: "update VM 901" from session-1244.scope).
        self.assertNotIn("unit", poller.QUERY)
        self.assertIn('job="journal"', poller.QUERY)


class Annotation(unittest.TestCase):
    def test_tags_name_the_source_node_user_and_action(self):
        got = poller.annotation(poller.parse(TASK, "rumba"), 1_700_000_000_123_456_789)
        self.assertEqual(got, {"time": 1_700_000_000_123, "text": "proxmox rumba: root@pam qmshutdown 201",
                               "tags": ["proxmox", "node:rumba", "user:root@pam", "action:qmshutdown"]})


class Fresh(unittest.TestCase):
    def a(self, ms, text):
        return {"time": ms, "text": text, "tags": ["proxmox"]}

    def test_everything_is_new_on_the_first_run(self):
        batch = [self.a(1, "x"), self.a(2, "y")]
        self.assertEqual(poller.fresh(batch, None, set()), batch)

    def test_lines_before_the_newest_posted_are_dropped(self):
        self.assertEqual(poller.fresh([self.a(5, "old"), self.a(9, "new")], 7, set()), [self.a(9, "new")])

    def test_a_line_in_the_same_millisecond_is_dropped_only_if_already_posted(self):
        batch = [self.a(7, "posted"), self.a(7, "also at 7"), self.a(8, "later")]
        self.assertEqual(poller.fresh(batch, 7, {"posted"}), [self.a(7, "also at 7"), self.a(8, "later")])

    def test_a_line_repeated_within_one_batch_is_posted_once(self):
        self.assertEqual(poller.fresh([self.a(3, "x"), self.a(3, "x")], None, set()), [self.a(3, "x")])


if __name__ == "__main__":
    unittest.main()
