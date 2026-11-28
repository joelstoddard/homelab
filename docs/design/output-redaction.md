# Output redaction

Ansible prints whatever a task hands it: a template line in a `--diff`, a
command's stdout at `-v`, the message of a failed assertion. `no_log: true`
hides a result only when someone remembers to set it, and it hides the whole
result. A `check-alloy --diff` printed a live password inline because a
template diff showed the line that held it. So redaction is a property of
Ansible's output, not of each task: every message passes through one set of
rules before it reaches the terminal or `log_path`.

## Design

`ansible.cfg` sets `stdout_callback = redact`, which loads
`ansible/plugins/callback/redact.py`. The plugin is Ansible's `default`
callback, unchanged, plus one step at start-up:

1. It decrypts every `*.sops.yaml` under `ansible/` (directories starting
   with `.` skipped), in parallel, with `sops --decrypt`. The values stay in
   memory for the run and are never written anywhere.
2. It wraps the `Display` singleton's `display`, `warning`, `error` and
   `deprecated` methods, so each message is redacted before Ansible prints or
   logs it.

Wrapping `Display` instead of the callback's own methods covers every path
with one hook: task results at any verbosity, failure messages, `debug`
output, `--diff`, warnings, `-vvv` connection lines, and `log_path`, which
`Display` writes from the same call. `warning`, `error` and `deprecated` are
wrapped as well as `display` because they word-wrap first, and a wrap can
split a value at a hyphen. Forked workers inherit the wrapper, and their
messages reach the main process through the same `Display` method.

## The rules

The rules live in `ansible/plugins/redact_rules.py`, shared with the
`talos_redact` filter. A secret becomes `<REDACTED sha256:xxxxxxxx>`:

1. **Any value from an Ansible SOPS file, wherever it appears.** This rests
   on the invariant that every secret lives in SOPS, so there is no list or
   naming convention to keep. The JSON-escaped form of each value is matched
   too, because a result dict prints a `"` or `\` escaped.
2. **Any opaque value.** A word of 24 or more base64/hex-like characters
   containing a digit, or a Kubernetes bootstrap token. Quotes and JSON
   punctuation around the word are ignored, so a value inside a printed
   result dict is still caught.

Why these two rules and not key names: `docs/design/talos-machine-config.md`,
"Redacting talosctl output".

The cost is readability in two places:
- Rule 2 hides file checksums and commit hashes, such as the `checksum` of an
  unchanged template at `-v`.
- Rule 1 matches substrings, so an encrypted address that is a prefix of
  another (`192.168.1.1` in `192.168.1.15`) leaves the tail digits after the marker.
  The output is wrong-looking, never revealing.

## Failure modes

- **No Age key, or no `sops`.** The callback warns once, naming the files it
  could not decrypt, and redacts their values by shape only. The run goes on;
  a task that loads the same file fails on its own.
- **A bug in redaction.** The message is replaced by
  `<output withheld: redaction failed>` with a warning. The raw text is never
  printed.
- **The plugin fails to start.** `ansible-playbook` stops with
  `Unexpected Exception` before any task runs. Decryption errors are caught,
  so only a bug in the plugin gets here.

## Limits

- **Output before the callback loads.** Ansible loads callbacks after the
  inventory. At `-v` and above, the NetBox inventory plugin's `Fetching:`
  lines print the NetBox URL unredacted, and that hostname is also a SOPS
  value.
- **Another callback.** `ANSIBLE_STDOUT_CALLBACK` in the environment replaces
  `redact`, and with it the redaction. Ad-hoc `ansible` and `ansible-console`
  (`make ping`, `make console`) use their own callback.
- **Not Ansible.** OpenTofu, `kubectl`, `flux` and shell output have no
  such hook. OpenTofu's `sensitive` marking is the tool there.

`no_log` stays where it is. It is the layer that keeps a value out of the
result entirely, and it holds when the callback is not loaded.

## Tests

`ansible/plugins/tests/test_redact_callback.py`, run by CI with the other
`test_*.py` directories. Unit tests feed canned results through the loaded
plugin with SOPS replaced by a decoy bundle. An end-to-end test copies the
plugin and `ansible.cfg` into a scratch tree, encrypts a decoy with a
throwaway Age key, and runs a playbook that prints it through `debug`, a `-vvv`
result, a `--diff`, a warning and a failure, then checks that stdout, stderr
and `log_path` never contain it. A second run with the `default` callback
shows the same playbook does print it.
