"""Tests for tasks/secrets.yaml. Run from ansible/roles/talos: python3 -m unittest discover tests

Each test runs the real task file through ansible-playbook against a scratch
directory, with a fake talosctl that writes a decoy bundle.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLAYBOOK_BIN = os.path.join(os.path.dirname(sys.executable), "ansible-playbook")
DECOY = "decoy-cluster-ca-value"

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: talos
        tasks_from: secrets
"""

FAKE_TALOSCTL = f"""\
#!/bin/sh
# Called as: gen secrets --force --output-file <path>
for last; do :; done
printf 'cluster:\\n  secret: {DECOY}\\n' > "$last"
"""


class SecretsBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.tracked = os.path.join(self.tmp, "files", "secrets.sops.yaml")
        self.build = os.path.join(self.tmp, "build")
        os.makedirs(os.path.dirname(self.tracked))
        os.makedirs(self.build)
        self.talosctl = self._write("talosctl", FAKE_TALOSCTL, 0o755)
        self.playbook = self._write("play.yaml", PLAYBOOK, 0o644)

    def _write(self, name, content, mode):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(content)
        os.chmod(path, mode)
        return path

    def _run(self, sops_bin):
        extra = (
            f"talosctl_bin={self.talosctl} sops_bin={sops_bin} "
            f"talos_secrets_sops={self.tracked} "
            f"talos_secrets_plain={os.path.join(self.build, 'secrets.yaml')}"
        )
        env = dict(os.environ, ANSIBLE_ROLES_PATH=ROLES)
        return subprocess.run(
            [PLAYBOOK_BIN, "-i", "localhost,", self.playbook, "-e", extra],
            cwd=self.tmp, env=env, capture_output=True, text=True,
        )

    def _files_holding_decoy(self):
        hits = []
        for root, _, names in os.walk(self.tmp):
            for name in names:
                path = os.path.join(root, name)
                with open(path, errors="ignore") as f:
                    if DECOY in f.read() and path != self.talosctl:
                        hits.append(os.path.relpath(path, self.tmp))
        return hits

    def test_failed_encrypt_leaves_no_plaintext_at_the_tracked_path(self):
        result = self._run(sops_bin="false")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(os.path.exists(self.tracked))

    def test_failed_encrypt_leaves_no_plaintext_anywhere(self):
        self._run(sops_bin="false")
        self.assertEqual(self._files_holding_decoy(), [])

    def test_successful_encrypt_commits_only_ciphertext(self):
        key = os.path.join(self.tmp, "age.key")
        subprocess.run(["age-keygen", "-o", key], check=True, capture_output=True)
        public = subprocess.run(
            ["age-keygen", "-y", key], check=True, capture_output=True, text=True
        ).stdout.strip()
        self._write(".sops.yaml", f"creation_rules:\n  - path_regex: files/.*\\.sops\\.yaml$\n    age: {public}\n", 0o644)

        result = self._run(sops_bin=shutil.which("sops"))

        self.assertEqual(result.returncode, 0, result.stdout)
        with open(self.tracked) as f:
            self.assertIn("ENC[", f.read())
        self.assertEqual(self._files_holding_decoy(), [])


if __name__ == "__main__":
    unittest.main()
