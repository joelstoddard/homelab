"""Tests for the redact stdout callback. Run: python -m unittest discover -s ansible/plugins/tests

Every value here is a decoy. Why the callback exists: docs/design/output-redaction.md.
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from ansible.executor.task_result import TaskResult
from ansible.inventory.host import Host
from ansible.playbook.task import Task
from ansible.plugins.loader import callback_loader, init_plugin_loader
from ansible.utils.display import Display

PLUGINS = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ANSIBLE_DIR = os.path.dirname(PLUGINS)
PLAYBOOK_BIN = os.path.join(os.path.dirname(sys.executable), "ansible-playbook")

# Stands in for the decrypted SOPS files: short, readable-looking, and one that JSON escapes.
BUNDLE = {
    "root_password": "hunter2-decoy",
    "dns": {"web_password": 'qu"ote-decoy'},
    "tokens": ["jointok3ndecoy", "decoy-passphrase"],
}
SECRETS = ["hunter2-decoy", 'qu"ote-decoy', "jointok3ndecoy", "decoy-passphrase"]
# Opaque but in no SOPS file: only the shape rule can catch it.
OPAQUE = "QWxhZGRpbjpvcGVuIHNlc2FtZVNlY3JldDEyMw"

init_plugin_loader()
callback_loader.add_directory(os.path.join(PLUGINS, "callback"))


def tag(value):
    return f"<REDACTED sha256:{hashlib.sha256(value.encode()).hexdigest()[:8]}>"


def make_callback(decrypt):
    """Load the plugin as ansible-playbook would, with SOPS replaced by `decrypt`."""
    cls = callback_loader.get("redact", class_only=True)
    module = sys.modules[cls.__module__]
    with mock.patch.object(module, "find_sops_files", return_value=["a.sops.yaml", "b.sops.yaml"]), \
            mock.patch.object(module, "sops_decrypt", side_effect=decrypt):
        cb = cls()
    cb.set_options()
    return cb, Display()


class CallbackCase(unittest.TestCase):
    decrypt = staticmethod(lambda path: BUNDLE if path == "a.sops.yaml" else {"empty": None})

    def setUp(self):
        self.out, self.err = io.StringIO(), io.StringIO()
        with self.capture():
            self.cb, self.display = make_callback(self.decrypt)
        self.addCleanup(self.display.__dict__.pop, "display", None)
        self.addCleanup(setattr, self.display, "verbosity", self.display.verbosity)
        self.task = Task.load({"name": "a task", "ansible.builtin.command": "echo hi"})

    def capture(self):
        stack = contextlib.ExitStack()
        stack.enter_context(contextlib.redirect_stdout(self.out))
        stack.enter_context(contextlib.redirect_stderr(self.err))
        return stack

    def result(self, data):
        return TaskResult(Host("h1"), self.task, data)

    def printed(self):
        return self.out.getvalue() + self.err.getvalue()

    def assert_no_secret(self, text):
        for value in SECRETS + [OPAQUE]:
            self.assertNotIn(value, text)
            self.assertNotIn(json.dumps(value)[1:-1], text)


class SopsValueTest(CallbackCase):
    """Rule 1: a value from any SOPS file, in every place the callback prints."""

    def test_stdout_stderr_msg_and_nested_results(self):
        self.display.verbosity = 3
        data = {
            "failed": True,
            "msg": "login failed for hunter2-decoy",
            "stdout": "token=jointok3ndecoy",
            "stderr": OPAQUE,
            "nested": {"list": [{"password": 'qu"ote-decoy'}]},
        }
        with self.capture():
            self.cb.v2_runner_on_failed(self.result(data))
            self.cb.v2_runner_on_ok(self.result(dict(data, failed=False)))
        out = self.printed()
        self.assert_no_secret(out)
        self.assertIn("login failed for " + tag("hunter2-decoy"), out)
        self.assertIn(tag(OPAQUE), out)

    def test_debug_output(self):
        data = {"msg": ["root password is hunter2-decoy"], "_ansible_verbose_always": True}
        self.task = Task.load({"name": "debug", "ansible.builtin.debug": {"msg": "x"}})
        with self.capture():
            self.cb.v2_runner_on_ok(self.result(data))
        self.assert_no_secret(self.printed())
        self.assertIn("root password is " + tag("hunter2-decoy"), self.printed())

    def test_diff_before_and_after(self):
        diff = {
            "before_header": "/etc/app.conf", "after_header": "/etc/app.conf",
            "before": "user = admin\npassword = hunter2-decoy\n",
            "after": "user = admin\npassword = jointok3ndecoy\n",
        }
        with self.capture():
            self.cb.v2_on_file_diff(self.result({"changed": True, "diff": diff}))
        out = self.printed()
        self.assert_no_secret(out)
        self.assertIn("-password = " + tag("hunter2-decoy"), out)
        self.assertIn("+password = " + tag("jointok3ndecoy"), out)
        self.assertIn(" user = admin", out)

    def test_warnings(self):
        with self.capture():
            self.cb.v2_runner_on_ok(self.result({"warnings": ["could not read hunter2-decoy"]}))
            self.display.warning("lookup failed on /nonexistent/jointok3ndecoy")
        self.assert_no_secret(self.err.getvalue())
        self.assertIn(tag("jointok3ndecoy"), self.err.getvalue())

    def test_warning_word_wrap_cannot_split_a_value(self):
        # One of these offsets puts the value across the wrap column.
        with self.capture():
            for pad in range(len("decoy-passphrase")):
                self.display.warning("x" * (self.display.columns - 14 - pad) + " decoy-passphrase")
        # textwrap breaks after a letter-hyphen, so a split leaves "decoy-" at a line end.
        self.assertNotIn("decoy-", self.err.getvalue())

    def test_readable_values_survive(self):
        self.display.verbosity = 1
        data = {
            "changed": True, "cmd": ["systemctl", "restart", "alloy"], "rc": 0,
            "stdout": "image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.10",
            "dest": "/etc/resolv.conf", "kind": "PodSecurityConfiguration",
        }
        with self.capture():
            self.cb.v2_runner_on_ok(self.result(data))
        out = self.printed()
        self.assertNotIn("REDACTED", out)
        for word in ["systemctl", "/etc/resolv.conf", "PodSecurityConfiguration", "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"]:
            self.assertIn(word, out)


class DegradeTest(CallbackCase):
    """Without the Age key, warn once and keep the shape rule; never fail the run."""

    @staticmethod
    def decrypt(path):
        raise RuntimeError("sops: failed to get the data key")

    def test_warns_once_and_falls_back_to_shape(self):
        self.assertEqual(self.err.getvalue().count("[WARNING]"), 1, self.err.getvalue())
        self.assertIn("shape", self.err.getvalue())
        with self.capture():
            self.cb.v2_runner_on_ok(self.result({"stdout": OPAQUE, "msg": "hunter2-decoy", "_ansible_verbose_always": True}))
        self.assertNotIn(OPAQUE, self.out.getvalue())
        self.assertIn("hunter2-decoy", self.out.getvalue())


class RedactionErrorTest(CallbackCase):
    """A redaction bug prints a placeholder and a warning, never the raw text."""

    def test_placeholder_not_raw_output(self):
        cls = callback_loader.get("redact", class_only=True)
        module = sys.modules[cls.__module__]
        with mock.patch.object(module, "redact", side_effect=ValueError("bug")), self.capture():
            self.display.display("password hunter2-decoy")
        out = self.printed()
        self.assertNotIn("hunter2-decoy", out)
        self.assertIn("output withheld", out)
        self.assertIn("[WARNING]", out)


# CI installs both for the secrets-bundle test.
AGE = shutil.which("age-keygen")
SOPS = shutil.which("sops")

PLAYBOOK = """\
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Load the decoy
      community.sops.load_vars:
        file: vars/decoy.sops.yaml
      no_log: true
    - name: Print it
      ansible.builtin.debug:
        msg: "decoy is {{ decoy_password }}"
    - name: Echo it
      ansible.builtin.command: echo {{ decoy_password }}
      changed_when: false
      check_mode: false
    - name: Diff it
      ansible.builtin.copy:
        content: "password = {{ decoy_password }}\\n"
        dest: "{{ playbook_dir }}/out.conf"
    - name: Warn it
      ansible.builtin.debug:
        msg: "{{ lookup('ansible.builtin.file', '/nonexistent/' ~ decoy_password, errors='warn') }}"
    - name: Fail on it
      ansible.builtin.fail:
        msg: "bad password {{ decoy_password }}"
"""


class PlaybookTest(unittest.TestCase):
    """End to end: a decoy SOPS value through debug, -v results, --diff, a warning and a failure."""

    DECOY = "hunter2-decoy"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        # The callback finds SOPS files relative to itself, so the tree is a copy of ansible/.
        shutil.copytree(PLUGINS, os.path.join(self.tmp, "plugins"), ignore=shutil.ignore_patterns("tests", "__pycache__"))
        shutil.copy(os.path.join(ANSIBLE_DIR, "ansible.cfg"), self.tmp)
        os.makedirs(os.path.join(self.tmp, "vars"))
        key = os.path.join(self.tmp, "age.key")
        subprocess.run([AGE, "-o", key], check=True, capture_output=True)
        public = subprocess.run([AGE, "-y", key], check=True, capture_output=True, text=True).stdout.strip()
        sops_file = os.path.join(self.tmp, "vars", "decoy.sops.yaml")
        with open(sops_file, "w") as f:
            f.write(f"decoy_password: {self.DECOY}\n")
        subprocess.run([SOPS, "--encrypt", "--age", public, "--in-place", sops_file], cwd=self.tmp, check=True, capture_output=True)
        with open(os.path.join(self.tmp, "out.conf"), "w") as f:
            f.write("password = old\n")
        with open(os.path.join(self.tmp, "play.yaml"), "w") as f:
            f.write(PLAYBOOK)
        self.env = dict(os.environ, SOPS_AGE_KEY_FILE=key, ANSIBLE_LOG_PATH=os.path.join(self.tmp, "ansible.log"))

    def run_play(self, **env):
        return subprocess.run(
            [PLAYBOOK_BIN, "-i", "localhost,", "play.yaml", "--check", "--diff", "-vvv"],
            cwd=self.tmp, env=dict(self.env, **env), capture_output=True, text=True,
        )

    def test_decoy_never_printed_or_logged(self):
        result = self.run_play()
        with open(self.env["ANSIBLE_LOG_PATH"]) as f:
            log = f.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bad password " + tag(self.DECOY), result.stdout + result.stderr)
        for text in (result.stdout, result.stderr, log):
            self.assertNotIn(self.DECOY, text)

    def test_decoy_printed_without_the_callback(self):
        result = self.run_play(ANSIBLE_STDOUT_CALLBACK="default")
        self.assertIn("bad password " + self.DECOY, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
