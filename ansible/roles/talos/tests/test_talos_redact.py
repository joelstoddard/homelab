"""Tests for the talos_redact filter. Run from ansible/roles/talos: python3 -m unittest discover tests"""
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "filter_plugins"))
from talos_redact import redact  # noqa: E402

# Stands in for the decrypted secrets bundle. Every value is a decoy.
BUNDLE = {
    "cluster": {"id": "Q2x1c3RlcklkRGVjb3k5OTk5OTk5OTk5OTk=", "secret": "shortSecret"},
    "secrets": {"bootstraptoken": "abcdef.0123456789abcdef"},
    "trustdinfo": {"token": "jointok3ndecoy"},
}

# A dry-run diff shaped like `talosctl apply-config --dry-run` output.
DIFF = """\
Dry run summary:
Applied configuration without a reboot (skipped in dry-run).

Config diff:

--- a
+++ b
@@ -3,12 +3,12 @@
 machine:
     type: controlplane
-    token: abcdef.0123456789abcdef
+    token: fedcba.9876543210fedcba
     ca:
         crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJQekNC
         key: LS0tLS1CRUdJTiBFRDI1NTE5IFBSSVZBVEUgS0VZLS0tLS0K
     nodeLabels:
-        topology.kubernetes.io/zone: rumba
+        topology.kubernetes.io/zone: tango
     install:
         image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.10
+    someNewField: QWxhZGRpbjpvcGVuIHNlc2FtZVNlY3JldFZhbHVlMTIz
     systemDiskEncryption:
         passphrase: correct-horse-battery
 cluster:
     id: Q2x1c3RlcklkRGVjb3k5OTk5OTk5OTk5OTk=
     secret: "shortSecret"
     apiServer:
         admissionControl:
           - configuration:
                 kind: PodSecurityConfiguration
     acceptedCAs:
       - ZGVjb3lDQWRlY295Q0FkZWNveUNBZGVjb3lDQQ1==
     certSANs:
       - 192.168.1.100
+apiUrl: https://siderolink.example.com?jointoken=jointok3ndecoy
+      MIIBPzCB8qADAgECAhEA3k9dG2x8Q0v1jR2b7pLkWzAFBgMrZXAwEDEOMAwGA1UE
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
addresses:
  - address: 192.168.1.51/20
"""


def tag(value):
    return f"<REDACTED sha256:{hashlib.sha256(value.encode()).hexdigest()[:8]}>"


class BundleRuleTest(unittest.TestCase):
    """Rule 1: any value from the secrets bundle, wherever it appears."""

    def setUp(self):
        self.out = redact(DIFF, BUNDLE)

    def test_every_bundle_value_is_gone(self):
        for value in ["Q2x1c3RlcklkRGVjb3k5OTk5OTk5OTk5OTk=", "shortSecret", "abcdef.0123456789abcdef", "jointok3ndecoy"]:
            self.assertNotIn(value, self.out)

    def test_short_bundle_secret_is_redacted_whatever_its_shape(self):
        self.assertIn(f'     secret: "{tag("shortSecret")}"', self.out)

    def test_bundle_value_inside_a_longer_value_is_redacted(self):
        self.assertIn("+apiUrl: https://siderolink.example.com?jointoken=" + tag("jointok3ndecoy"), self.out)

    def test_short_bundle_secret_survives_without_the_bundle(self):
        self.assertIn('     secret: "shortSecret"', redact(DIFF).splitlines())


class ShapeRuleTest(unittest.TestCase):
    """Rule 2: an opaque value, with or without the bundle."""

    def setUp(self):
        self.out = redact(DIFF)

    def test_generated_secrets_are_redacted_by_shape(self):
        for value in [
            "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJQekNC",
            "LS0tLS1CRUdJTiBFRDI1NTE5IFBSSVZBVEUgS0VZLS0tLS0K",
            "QWxhZGRpbjpvcGVuIHNlc2FtZVNlY3JldFZhbHVlMTIz",
            "ZGVjb3lDQWRlY295Q0FkZWNveUNBZGVjb3lDQQ1==",
            "fedcba.9876543210fedcba",
        ]:
            self.assertNotIn(value, self.out)

    def test_raw_pem_body_line_is_redacted(self):
        self.assertIn("+      " + tag("MIIBPzCB8qADAgECAhEA3k9dG2x8Q0v1jR2b7pLkWzAFBgMrZXAwEDEOMAwGA1UE"), self.out)

    def test_changed_secret_shows_different_hashes(self):
        both = redact(DIFF, BUNDLE)
        self.assertIn("-    token: " + tag("abcdef.0123456789abcdef"), both)
        self.assertIn("+    token: " + tag("fedcba.9876543210fedcba"), both)

    def test_opaque_needs_a_digit_so_plain_words_survive(self):
        self.assertIn("                 kind: PodSecurityConfiguration", self.out.splitlines())

    def test_names_do_not_redact(self):
        # No key-name rule: a non-bundle, non-opaque value is shown whatever its key.
        self.assertIn("         passphrase: correct-horse-battery", self.out.splitlines())


class ReadableTest(unittest.TestCase):
    def test_readable_lines_survive_untouched(self):
        out = redact(DIFF, BUNDLE).splitlines()
        for line in [
            "-        topology.kubernetes.io/zone: rumba",
            "+        topology.kubernetes.io/zone: tango",
            "         image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.10",
            "       - 192.168.1.100",
            "  - address: 192.168.1.51/20",
            "--- a",
            "+++ b",
            "@@ -3,12 +3,12 @@",
            "kind: LinkConfig",
        ]:
            self.assertIn(line, out)

    def test_no_changes_output_is_unchanged(self):
        text = "Dry run summary:\nNo changes.\n"
        self.assertEqual(redact(text, BUNDLE), text)

    def test_none_and_empty(self):
        self.assertEqual(redact(""), "")
        self.assertEqual(redact(None), "")


if __name__ == "__main__":
    unittest.main()
