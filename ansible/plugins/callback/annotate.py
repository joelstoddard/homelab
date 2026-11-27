"""annotate: marks a playbook run that changed something as an Operator annotation in Grafana.

One region per run, from the playbook's start to its stats; none for --check or a run that
changed nothing. Why: docs/design/observability.md, "Change annotations". Tests:
ansible/plugins/tests.
"""
import os
import subprocess
import time

from ansible import context
from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
    name: annotate
    type: aggregate
    short_description: post a Grafana annotation for a run that changed something
    description:
      - At the end of a playbook run, calls scripts/annotate with a region covering the run,
        when a task changed something and the run was not --check.
    requirements:
      - enabled in callbacks_enabled
      - scripts/annotate, sops and the Age key; without them the run warns and continues
"""

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
SCRIPT = os.path.join(REPO, "scripts", "annotate")


def describe(playbook, summary, check):
    """The annotation text for a run, or None when the run should leave no mark."""
    if check:
        return None
    changed = {h: s["changed"] for h, s in summary.items() if s["changed"]}
    if not changed:
        return None
    total = sum(changed.values())
    text = f"ansible: {playbook} changed {total} task{'' if total == 1 else 's'} on {', '.join(sorted(changed))}"
    failed = sorted(h for h, s in summary.items() if s["failures"] or s["unreachable"])
    if failed:
        text += f"; failed on {', '.join(failed)}"
    return text


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "annotate"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.script = SCRIPT
        self.check = bool(context.CLIARGS.get("check", False))
        self.playbook = "?"
        self.start_ms = int(time.time() * 1000)

    def v2_playbook_on_start(self, playbook):
        self.playbook = os.path.basename(playbook._file_name)
        self.start_ms = int(time.time() * 1000)

    def v2_playbook_on_stats(self, stats):
        self.post({h: stats.summarize(h) for h in sorted(stats.processed)})

    def post(self, summary):
        text = describe(self.playbook, summary, self.check)
        if text is None:
            return
        tags = [f"playbook:{self.playbook}"]
        if any(s["failures"] or s["unreachable"] for s in summary.values()):
            tags.append("failed")
        env = dict(os.environ, ANNOTATE_START_MS=str(self.start_ms), ANNOTATE_END_MS=str(int(time.time() * 1000)))
        # A run's outcome never depends on its annotation: any error is a warning.
        try:
            subprocess.run([self.script, "ansible", text, *tags], env=env, timeout=30, check=False)
        except (OSError, subprocess.SubprocessError) as e:
            self._display.warning(f"annotate: {e}; no annotation posted")
