"""talos_redact: strip secret values from talosctl output before Ansible prints it.

Usage: {{ result.stdout | talos_redact(secrets) }}, where secrets is the decrypted
secrets bundle (any nesting of dicts and lists). The rules live in
ansible/plugins/redact_rules.py, shared with the redact stdout callback. Tests:
python3 -m unittest discover tests (from the role directory). Why:
docs/design/talos-machine-config.md.
"""
import os
import sys

# Plugins outside a collection cannot import module_utils, so the shared rules load by path.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "..", "plugins"))
from redact_rules import redact  # noqa: E402


class FilterModule(object):
    def filters(self):
        return {"talos_redact": redact}
