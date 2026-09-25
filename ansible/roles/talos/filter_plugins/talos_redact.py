"""talos_redact: strip secret values from talosctl output before Ansible prints it.

Usage: {{ result.stdout | talos_redact }}. Each secret value becomes
<REDACTED sha256:xxxxxxxx>, so a diff still shows which keys changed and whether a
value changed, but not the value. Tests: python3 -m unittest discover tests (from
the role directory). Why both rules exist: docs/design/talos-machine-config.md.
"""
import hashlib
import re

# Keys whose value is secret whatever its shape (compared lower-cased, by suffix).
SECRET_KEY_SUFFIXES = ("key", "token", "secret", "password")

# A value is secret by shape when it is one opaque base64/hex-like string of 24+
# characters, or a Kubernetes bootstrap token.
OPAQUE = re.compile(r"^[A-Za-z0-9+/=_-]{24,}$")
BOOTSTRAP_TOKEN = re.compile(r"^[a-z0-9]{6}\.[a-z0-9]{16}$")

# "<diff prefix><indent><optional '- '>key: value" and "<prefix><indent>- value".
KEY_LINE = re.compile(r"^(?P<lead>[ +-]?\s*(?:-\s+)?)(?P<key>[A-Za-z0-9_./-]+):(?P<gap>\s+)(?P<val>\S.*?)\s*$")
ITEM_LINE = re.compile(r"^(?P<lead>[ +-]?\s*-\s+)(?P<val>\S+)\s*$")


def _tag(value):
    return "<REDACTED sha256:%s>" % hashlib.sha256(value.encode()).hexdigest()[:8]


def _opaque(value):
    return bool(OPAQUE.match(value) or BOOTSTRAP_TOKEN.match(value))


def _redact_line(line):
    m = KEY_LINE.match(line)
    if m:
        value = m.group("val").strip("'\"")
        if m.group("key").lower().endswith(SECRET_KEY_SUFFIXES) or _opaque(value):
            return m.group("lead") + m.group("key") + ":" + m.group("gap") + _tag(value)
        return line
    m = ITEM_LINE.match(line)
    if m and _opaque(m.group("val").strip("'\"")):
        return m.group("lead") + _tag(m.group("val").strip("'\""))
    return line


def redact(text):
    if not text:
        return ""
    return "\n".join(_redact_line(line) for line in text.split("\n"))


class FilterModule(object):
    def filters(self):
        return {"talos_redact": redact}
