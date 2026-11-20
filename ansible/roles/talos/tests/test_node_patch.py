"""Tests for templates/patches/node.yaml.j2. Run from ansible/roles/talos: python3 -m unittest discover tests

Each test renders the real template through ansible-playbook and parses the documents.
"""
import json
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
    node-a: {ansible_host: 192.168.1.21}
    Node-B: {ansible_host: 192.168.1.22}
"""

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    talos_controlplane_hosts: []
    talos_static_network: false
    talos_version: v1.13.10
    talos_schematic_id: vm
    talos_pi_schematic_id: pi
    talos_logging_port: 5170
  tasks:
    - ansible.builtin.template:
        src: "{{ roles_dir }}/talos/templates/patches/node.yaml.j2"
        dest: "{{ out }}"
        mode: "0600"
"""


class NodePatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inventory = self._write("inventory.yaml", INVENTORY)
        self.playbook = self._write("play.yaml", PLAYBOOK)
        self.out = os.path.join(self.tmp, "node.yaml")

    def _write(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def _render(self, address, node="node-a"):
        args = [PLAYBOOK_BIN, "-i", self.inventory, self.playbook,
                "-e", f"roles_dir={ROLES}", "-e", f"out={self.out}",
                "-e", json.dumps({"talos_logging_address": address, "node": node})]
        result = subprocess.run(args, cwd=self.tmp, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        with open(self.out) as f:
            return [d for d in yaml.safe_load_all(f) if d]

    def _kmsg(self, docs):
        return [d for d in docs if d.get("kind") == "KmsgLogConfig"]

    def test_address_adds_destination_tagged_with_the_node(self):
        docs = self._render("192.168.1.50")
        self.assertEqual(docs[0]["machine"]["logging"]["destinations"], [{
            "endpoint": "tcp://192.168.1.50:5170/",
            "format": "json_lines",
            "extraTags": {"node": "node-a"},
        }])

    def test_node_tag_is_lowercase_like_the_kubernetes_node_name(self):
        # NetBox capitalises the Pis' names; every other label uses the lowercase node name.
        docs = self._render("192.168.1.50", node="Node-B")
        self.assertEqual(docs[0]["machine"]["logging"]["destinations"][0]["extraTags"], {"node": "node-b"})

    def test_address_adds_no_kernel_log_document(self):
        # The service stream already carries kernel lines, with the node tag.
        self.assertEqual(self._kmsg(self._render("192.168.1.50")), [])

    def test_no_address_no_logging(self):
        docs = self._render("")
        self.assertNotIn("logging", docs[0]["machine"])
        self.assertEqual(self._kmsg(docs), [])


if __name__ == "__main__":
    unittest.main()
