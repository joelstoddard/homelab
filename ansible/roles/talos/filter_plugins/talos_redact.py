"""talos_redact: strip secret values from talosctl output before Ansible prints it.

Usage: {{ result.stdout | talos_redact(secrets) }}, where secrets is the decrypted
secrets bundle (any nesting of dicts and lists). Each secret value becomes
<REDACTED sha256:xxxxxxxx>. A value is secret when it is in the bundle, or when it
looks opaque; no key names are involved. Tests: python3 -m unittest discover tests
(from the role directory). Why: docs/design/talos-machine-config.md.
"""
import hashlib
import re

# Opaque: 24+ base64/hex-like characters with at least one digit, or a bootstrap token.
OPAQUE = re.compile(r"^(?=.*[0-9])[A-Za-z0-9+/=_-]{24,}$")
BOOTSTRAP_TOKEN = re.compile(r"^[a-z0-9]{6}\.[a-z0-9]{16}$")
WORD = re.compile(r"\S+")


def _tag(value):
    return f"<REDACTED sha256:{hashlib.sha256(value.encode()).hexdigest()[:8]}>"


def _values(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from _values(v)
    elif isinstance(node, (list, tuple, set)):
        for v in node:
            yield from _values(v)
    elif node not in (None, "") and not isinstance(node, bool):
        yield str(node)


def _redact_word(match):
    word = match.group(0)
    bare = word.strip("'\"")
    if OPAQUE.match(bare) or BOOTSTRAP_TOKEN.match(bare):
        return word.replace(bare, _tag(bare))
    return word


def redact(text, secrets=None):
    if not text:
        return ""
    # Longest first, so a value that contains another is replaced whole.
    for value in sorted(set(_values(secrets)), key=len, reverse=True):
        text = text.replace(value, _tag(value))
    return WORD.sub(_redact_word, text)


class FilterModule(object):
    def filters(self):
        return {"talos_redact": redact}
