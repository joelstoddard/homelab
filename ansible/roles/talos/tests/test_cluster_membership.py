"""Tests for tasks/cluster.yaml. Run from ansible/roles/talos: python3 -m unittest discover tests

Each test runs the real task file through ansible-playbook against a static
inventory of Talos hosts at two NetBox sites.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLAYBOOK_BIN = os.path.join(os.path.dirname(sys.executable), "ansible-playbook")

INVENTORY = """\
talos:
  hosts:
    home-a: {site: homelab}
    home-b: {site: homelab}
    remote-a: {site: elsewhere}
"""

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.import_role:
        name: talos
        tasks_from: cluster
    - ansible.builtin.debug:
        msg: "MEMBERS={{ talos_cluster_hosts | sort | join(',') }}"
"""


class ClusterMembershipTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inventory = self._write("inventory.yaml", INVENTORY)
        self.playbook = self._write("play.yaml", PLAYBOOK)

    def _write(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def _run(self, *extra):
        args = [PLAYBOOK_BIN, "-i", self.inventory, self.playbook]
        for e in extra:
            args += ["-e", e]
        env = dict(os.environ, ANSIBLE_ROLES_PATH=ROLES)
        return subprocess.run(args, cwd=self.tmp, env=env, capture_output=True, text=True)

    def test_home_cluster_is_the_talos_hosts_at_its_site(self):
        result = self._run("talos_cluster=homelab")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("MEMBERS=home-a,home-b", result.stdout)

    def test_a_cluster_with_no_hosts_at_its_site_fails(self):
        result = self._run("talos_cluster=homelab", "talos_cluster_site=nowhere")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("No Talos hosts at NetBox site 'nowhere'", result.stdout)

    def test_a_missing_required_var_fails_naming_it(self):
        result = self._run("talos_cluster=homelab", '{"talos_cluster_required_vars": ["talos_absent_key"]}')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("talos_absent_key", result.stdout)

    def test_a_tailnet_reached_cluster_must_be_one_node(self):
        result = self._run("talos_cluster=homelab", "talos_api_address=node.example.com")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("exactly one node", result.stdout)


if __name__ == "__main__":
    unittest.main()
