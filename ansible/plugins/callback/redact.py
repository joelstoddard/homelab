"""redact: the default stdout callback, with every line Ansible prints passed through redact_rules.

Why and how: docs/design/output-redaction.md. Tests: ansible/plugins/tests.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from ansible import constants as C
from ansible.plugins.callback.default import CallbackModule as DefaultCallback

# Plugins outside a collection cannot import module_utils, so the shared rules load by path.
PLUGINS_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, PLUGINS_DIR)
from redact_rules import redact  # noqa: E402

DOCUMENTATION = """
    name: redact
    type: stdout
    short_description: default output with SOPS values and opaque strings redacted
    description:
      - The default callback, with every message Display prints passed through the redaction rules.
    extends_documentation_fragment:
      - default_callback
      - result_format_callback
    requirements:
      - set as stdout in configuration
      - sops on PATH, and the Age key, for the SOPS-value rule
"""

ANSIBLE_DIR = os.path.dirname(PLUGINS_DIR)
PLACEHOLDER = "<output withheld: redaction failed>"
GUARDED = ("display", "warning", "error", "deprecated")


def find_sops_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Skips .venv and the git-ignored .talos build output.
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        found += [os.path.join(dirpath, f) for f in filenames if f.endswith(".sops.yaml")]
    return sorted(found)


def sops_decrypt(path):
    try:
        out = subprocess.run(
            ["sops", "--decrypt", "--output-type", "json", path],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30, check=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        raise RuntimeError(e.stderr.strip().splitlines()[0] if e.stderr.strip() else f"exit {e.returncode}") from None
    return json.loads(out)


def load_secrets(paths):
    """Decrypt every file in parallel; return (decrypted data, {path: reason} for failures)."""
    def attempt(path):
        try:
            return sops_decrypt(path), None
        except Exception as e:
            return None, f"{type(e).__name__}: {e}"

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(attempt, paths))
    secrets = [data for data, _ in results if data is not None]
    failures = {path: reason for path, (_, reason) in zip(paths, results) if reason}
    return secrets, failures


def _with_msg(args, kwargs, change):
    if args and isinstance(args[0], str):
        return (change(args[0]),) + args[1:], kwargs
    if isinstance(kwargs.get("msg"), str):
        return args, dict(kwargs, msg=change(kwargs["msg"]))
    return args, kwargs


def install(display, secrets):
    """Wrap the Display singleton's printing methods so every message is redacted first.

    warning/error/deprecated are wrapped too because they word-wrap before calling display(),
    which could split a value across lines. Forked workers inherit the wrappers.
    """
    plain_display = getattr(type(display), "display").__get__(display)

    def guard(method):
        def wrapper(*args, **kwargs):
            try:
                args, kwargs = _with_msg(args, kwargs, lambda msg: redact(msg, secrets))
            except Exception as e:
                plain_display(f"[WARNING]: redact: {type(e).__name__} while redacting; output withheld",
                              color=C.COLOR_WARN, stderr=True)
                args, kwargs = _with_msg(args, kwargs, lambda msg: PLACEHOLDER)
            return method(*args, **kwargs)
        return wrapper

    for name in GUARDED:
        setattr(display, name, guard(getattr(type(display), name).__get__(display)))


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "redact"

    def __init__(self):
        super().__init__()
        secrets, failures = load_secrets(find_sops_files(ANSIBLE_DIR))
        install(self._display, secrets)
        if failures:
            names = ", ".join(os.path.relpath(p, ANSIBLE_DIR) for p in failures)
            self._display.warning(
                f"redact: could not decrypt {names} ({next(iter(failures.values()))}); "
                "their values are redacted by shape only"
            )
