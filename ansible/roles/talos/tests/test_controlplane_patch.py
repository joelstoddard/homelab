"""Tests for templates/patches/controlplane.yaml.j2. Run from ansible/roles/talos: python3 -m unittest discover tests

Each test renders the real template through ansible-playbook and parses the documents.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLAYBOOK_BIN = os.path.join(os.path.dirname(sys.executable), "ansible-playbook")

INVENTORY = """\
talos:
  hosts:
    cp-a: {ansible_host: 192.168.1.11}
    cp-b: {ansible_host: 192.168.1.12}
    worker-a: {ansible_host: 192.168.1.21}
    worker-b: {ansible_host: 192.168.1.22}
"""

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    talos_cluster_hosts: [cp-a, cp-b, worker-a, worker-b]
    talos_controlplane_hosts: [cp-a, cp-b]
    talos_vip: 192.168.1.100
  tasks:
    - ansible.builtin.template:
        src: "{{ roles_dir }}/talos/templates/patches/controlplane.yaml.j2"
        dest: "{{ out }}"
        mode: "0600"
"""


class ControlplanePatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inventory = self._write("inventory.yaml", INVENTORY)
        self.playbook = self._write("play.yaml", PLAYBOOK)
        self.out = os.path.join(self.tmp, "controlplane.yaml")

    def _write(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def _render(self, static_network):
        args = [PLAYBOOK_BIN, "-i", self.inventory, self.playbook,
                "-e", f"roles_dir={ROLES}", "-e", f"out={self.out}",
                "-e", f'{{"talos_static_network": {str(static_network).lower()}}}']
        result = subprocess.run(args, cwd=self.tmp, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        with open(self.out) as f:
            return [d for d in yaml.safe_load_all(f) if d]

    def _etcd_metrics_rule(self, docs):
        return [d for d in docs if d.get("kind") == "NetworkRuleConfig" and d.get("name") == "etcd-metrics"]

    def test_etcd_metrics_admits_only_the_workers(self):
        rules = self._etcd_metrics_rule(self._render(static_network=True))
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0]["portSelector"], {"ports": [2381], "protocol": "tcp"})
        self.assertEqual(
            [i["subnet"] for i in rules[0]["ingress"]],
            ["192.168.1.21/32", "192.168.1.22/32"],
        )

    def test_no_rule_without_static_node_addresses(self):
        self.assertEqual(self._etcd_metrics_rule(self._render(static_network=False)), [])

    def test_no_default_action_is_set(self):
        docs = self._render(static_network=True)
        self.assertFalse([d for d in docs if d.get("kind") == "NetworkDefaultActionConfig"])


if __name__ == "__main__":
    unittest.main()
