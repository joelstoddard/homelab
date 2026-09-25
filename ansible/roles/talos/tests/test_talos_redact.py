"""Tests for the talos_redact filter. Run from ansible/roles/talos: python3 -m unittest discover tests"""
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "filter_plugins"))
from talos_redact import redact  # noqa: E402

# A dry-run diff shaped like `talosctl apply-config --dry-run` output. Every
# secret-looking value below is a decoy; the test fails if any survives.
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
 cluster:
     secret: "shortSecret"
     aescbcEncryptionSecret: z01mye6j16bspJYtTB/5SFX9ntmSYcjVOSGafKkDE/c=
     acceptedCAs:
       - ZGVjb3lDQWRlY295Q0FkZWNveUNBZGVjb3lDQQ==
     certSANs:
       - 192.168.1.100
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
addresses:
  - address: 192.168.1.51/20
"""

DECOYS = [
    "abcdef.0123456789abcdef",
    "fedcba.9876543210fedcba",
    "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJQekNC",
    "LS0tLS1CRUdJTiBFRDI1NTE5IFBSSVZBVEUgS0VZLS0tLS0K",
    "QWxhZGRpbjpvcGVuIHNlc2FtZVNlY3JldFZhbHVlMTIz",
    "shortSecret",
    "z01mye6j16bspJYtTB/5SFX9ntmSYcjVOSGafKkDE/c=",
    "ZGVjb3lDQWRlY295Q0FkZWNveUNBZGVjb3lDQQ==",
]


def tag(value):
    return "<REDACTED sha256:%s>" % hashlib.sha256(value.encode()).hexdigest()[:8]


class RedactTest(unittest.TestCase):
    def setUp(self):
        self.out = redact(DIFF)

    def test_no_decoy_survives(self):
        for decoy in DECOYS:
            self.assertNotIn(decoy, self.out)

    def test_known_secret_keys_are_redacted_even_when_short(self):
        self.assertIn('     secret: ' + tag("shortSecret"), self.out)

    def test_unknown_key_with_opaque_value_is_redacted(self):
        self.assertIn("+    someNewField: " + tag("QWxhZGRpbjpvcGVuIHNlc2FtZVNlY3JldFZhbHVlMTIz"), self.out)

    def test_bare_list_item_with_opaque_value_is_redacted(self):
        self.assertIn("       - " + tag("ZGVjb3lDQWRlY295Q0FkZWNveUNBZGVjb3lDQQ=="), self.out)

    def test_changed_secret_shows_different_hashes(self):
        self.assertIn("-    token: " + tag("abcdef.0123456789abcdef"), self.out)
        self.assertIn("+    token: " + tag("fedcba.9876543210fedcba"), self.out)
        self.assertNotEqual(tag("abcdef.0123456789abcdef"), tag("fedcba.9876543210fedcba"))

    def test_readable_lines_survive_untouched(self):
        for line in [
            "-        topology.kubernetes.io/zone: rumba",
            "+        topology.kubernetes.io/zone: tango",
            "         image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.10",
            "       - 192.168.1.100",
            "  - address: 192.168.1.51/20",
            "--- a",
            "+++ b",
            "@@ -3,12 +3,12 @@",
            "Dry run summary:",
            "kind: LinkConfig",
        ]:
            self.assertIn(line, self.out.splitlines())

    def test_no_changes_output_is_unchanged(self):
        text = "Dry run summary:\nNo changes.\n"
        self.assertEqual(redact(text), text)

    def test_none_and_empty(self):
        self.assertEqual(redact(""), "")
        self.assertEqual(redact(None), "")


if __name__ == "__main__":
    unittest.main()
