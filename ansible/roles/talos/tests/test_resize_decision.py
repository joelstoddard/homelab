"""Tests for tasks/resize-decision.yaml. Run from ansible/roles/talos: python3 -m unittest discover tests

Each test runs the real task file through ansible-playbook with a Proxmox
pending-config listing shaped like `pvesh get .../qemu/<vmid>/pending`.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLAYBOOK_BIN = os.path.join(os.path.dirname(sys.executable), "ansible-playbook")

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.import_role:
        name: talos
        tasks_from: resize-decision
    - ansible.builtin.debug:
        msg: "NEEDED={{ talos_resize_needed }} FLOOR={{ talos_resize_floor_mb }}"
"""


def config(balloon=0, memory=5000, balloon_change=None):
    """balloon=None leaves the key unset; balloon_change adds a pending or delete field."""
    items = [{"key": "memory", "value": str(memory)}, {"key": "cores", "value": 4}]
    if balloon is not None:
        items.append(dict({"key": "balloon", "value": balloon}, **(balloon_change or {})))
    return items


class ResizeDecisionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.playbook = os.path.join(self.tmp, "play.yaml")
        with open(self.playbook, "w") as f:
            f.write(PLAYBOOK)

    def _decide(self, seen, items, memory=5000):
        extra = {"memory": memory, "talos_resize_seen_mb": seen, "talos_resize_config": items}
        args = [PLAYBOOK_BIN, "-i", "localhost,", self.playbook, "-e", json.dumps(extra)]
        env = dict(os.environ, ANSIBLE_ROLES_PATH=ROLES)
        result = subprocess.run(args, cwd=self.tmp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def test_ballooned_guest_at_its_minimum_is_sized(self):
        out = self._decide(3768, config(balloon=4000))
        self.assertIn("NEEDED=False FLOOR=4000", out)

    def test_unballooned_guest_at_full_memory_is_sized(self):
        out = self._decide(4768, config(balloon=0))
        self.assertIn("NEEDED=False FLOOR=5000", out)

    def test_unset_balloon_means_the_minimum_is_full_memory(self):
        self.assertIn("NEEDED=False FLOOR=5000", self._decide(4768, config(balloon=None)))
        self.assertIn("NEEDED=True", self._decide(3768, config(balloon=None)))

    def test_pending_balloon_cycles_a_correctly_sized_guest(self):
        out = self._decide(4768, config(balloon=0, balloon_change={"pending": 4000}))
        self.assertIn("NEEDED=True FLOOR=5000", out)

    def test_pending_delete_cycles(self):
        out = self._decide(3768, config(balloon=4000, balloon_change={"delete": 1}))
        self.assertIn("NEEDED=True", out)

    def test_guest_seeing_more_than_netbox_is_a_shrink(self):
        out = self._decide(5768, config(balloon=4000, memory=6000))
        self.assertIn("NEEDED=True", out)

    def test_ballooned_guest_below_its_minimum_cycles(self):
        out = self._decide(3000, config(balloon=4000))
        self.assertIn("NEEDED=True", out)


if __name__ == "__main__":
    unittest.main()
