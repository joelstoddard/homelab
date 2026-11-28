"""Tests for scripts/lib/fetch-verified.sh. Run: python3 -m unittest discover -s scripts

install.sh installs nothing whose SHA-256 differs from its release's checksum file.
file:// URLs stand in for the release, so the tests touch no network.
"""
import hashlib
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "lib", "fetch-verified.sh")
ASSET = "tool_1.0_linux_amd64.tar.gz"


class FetchVerified(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.payload = b"pretend release binary\n"
        with open(os.path.join(self.tmp, ASSET), "wb") as f:
            f.write(self.payload)
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.dest = os.path.join(self.tmp, "installed")

    def sums(self, text):
        path = os.path.join(self.tmp, "SHA256SUMS")
        with open(path, "w") as f:
            f.write(text)
        return f"file://{path}"

    def fetch(self, sums_url):
        return subprocess.run(
            ["bash", "-c", f'. "{LIB}"; fetch_verified "$@"', "fetch",
             f"file://{self.tmp}/{ASSET}", sums_url, ASSET, self.dest],
            capture_output=True, text=True)

    def test_matching_sum_installs_the_asset(self):
        r = self.fetch(self.sums(f"{'0' * 64}  other.tar.gz\n{self.digest}  {ASSET}\n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.dest, "rb") as f:
            self.assertEqual(f.read(), self.payload)

    def test_changed_sum_refuses_and_installs_nothing(self):
        bad = ("1" if self.digest[0] != "1" else "2") + self.digest[1:]
        r = self.fetch(self.sums(f"{bad}  {ASSET}\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"checksum mismatch: {ASSET}", r.stderr)
        self.assertFalse(os.path.exists(self.dest))

    def test_sums_file_without_the_asset_refuses(self):
        r = self.fetch(self.sums(f"{self.digest}  other.tar.gz\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"no checksum for: {ASSET}", r.stderr)
        self.assertFalse(os.path.exists(self.dest))

    def test_bare_hash_file_is_accepted(self):
        r = self.fetch(self.sums(f"{self.digest}\n"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.dest))

    def test_unreachable_asset_refuses(self):
        os.remove(os.path.join(self.tmp, ASSET))
        r = self.fetch(self.sums(f"{self.digest}  {ASSET}\n"))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.dest))


if __name__ == "__main__":
    unittest.main()
