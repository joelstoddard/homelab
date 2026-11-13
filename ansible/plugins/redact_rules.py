"""The two redaction rules shared by the talos_redact filter and the redact stdout callback.

redact(text, secrets) rewrites each secret value as <REDACTED sha256:xxxxxxxx>. A value
is secret when it is in `secrets` (any nesting of dicts and lists), or when it looks
opaque; no key names are involved. Why: docs/design/talos-machine-config.md and
docs/design/output-redaction.md.
"""
import hashlib
import json
import re

# Opaque: 24+ base64/hex-like characters with at least one digit, or a bootstrap token.
OPAQUE = re.compile(r"^(?=.*[0-9])[A-Za-z0-9+/=_-]{24,}$")
BOOTSTRAP_TOKEN = re.compile(r"^[a-z0-9]{6}\.[a-z0-9]{16}$")
WORD = re.compile(r"\S+")
# Quotes and JSON/YAML punctuation around a value, as Ansible prints results.
WRAPPING = "'\"`,;:{}[]()\\"


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


def secret_strings(secrets):
    """Map every value in `secrets`, and the JSON-escaped forms a result prints, to the value."""
    found = {}
    for value in _values(secrets):
        for form in (value, json.dumps(value)[1:-1], json.dumps(value, ensure_ascii=False)[1:-1]):
            found[form] = value
    return found


def _redact_word(match):
    word = match.group(0)
    bare = word.strip(WRAPPING)
    if OPAQUE.match(bare) or BOOTSTRAP_TOKEN.match(bare):
        return word.replace(bare, _tag(bare))
    return word


def redact(text, secrets=None):
    if not text:
        return ""
    # Longest first, so a value that contains another is replaced whole.
    forms = secret_strings(secrets)
    for form in sorted(forms, key=len, reverse=True):
        text = text.replace(form, _tag(forms[form]))
    return WORD.sub(_redact_word, text)
