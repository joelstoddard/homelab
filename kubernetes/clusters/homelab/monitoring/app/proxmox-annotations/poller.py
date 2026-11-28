"""Posts Proxmox changes from the NUCs' journal (in Loki) as Grafana annotations tagged proxmox.

Runs as the proxmox-annotations CronJob. Grafana's newest proxmox annotation is the only state.
Why and how: docs/design/observability.md, "Change annotations".
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

LOKI = os.environ.get("LOKI_URL", "http://loki.monitoring.svc:3100")
GRAFANA = os.environ.get("GRAFANA_URL", "http://grafana.monitoring.svc")
BACKFILL_NS = 30 * 86400 * 10**9
# No unit filter: pvesh and qm log a change under the shell session that ran them.
QUERY = '{job="journal"} |~ "<[^>]+> (starting task UPID|update (VM|CT) )"'
LIMIT = 5000

# Tasks Proxmox runs on a schedule that change nothing: aptupdate refreshes package lists daily.
ROUTINE = {"aptupdate"}
TASK = re.compile(r"<(?P<user>[^>]+)> starting task UPID:[^:]+:[^:]+:[^:]+:[^:]+:(?P<type>[^:]+):(?P<id>[^:]*):")
UPDATE = re.compile(r"<(?P<user>[^>]+)> (?P<what>update (?:VM|CT) \d+: .*)$")


def parse(line, node):
    """A change from one journal line, or None for anything that is not one or that OpenTofu made."""
    m = TASK.search(line)
    if m:
        user, action, rest = m["user"], m["type"], f"{m['type']} {m['id']}".rstrip()
    else:
        m = UPDATE.search(line)
        if not m:
            return None
        user, action, rest = m["user"], "update", m["what"].rstrip()
    # OpenTofu's API token: its applies already post an Operator annotation.
    if user.endswith("!terraform") or action in ROUTINE:
        return None
    return {"node": node, "user": user, "action": action, "text": f"proxmox {node}: {user} {rest}"}


def annotation(change, ts_ns):
    return {"time": ts_ns // 10**6, "text": change["text"],
            "tags": ["proxmox", f"node:{change['node']}", f"user:{change['user']}", f"action:{change['action']}"]}


def fresh(batch, last_ms, posted_at_last):
    """The annotations not yet in Grafana, given its newest proxmox time and the texts posted then."""
    seen, out = set(), []
    for a in batch:
        key = (a["time"], a["text"])
        if key in seen:
            continue
        seen.add(key)
        if last_ms is not None and (a["time"] < last_ms or (a["time"] == last_ms and a["text"] in posted_at_last)):
            continue
        out.append(a)
    return out


def request(url, token=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=30) as r:
        return json.load(r)


def main():
    token = os.environ["GRAFANA_TOKEN"]
    newest = request(f"{GRAFANA}/api/annotations?tags=proxmox&limit=1", token)
    last_ms = newest[0]["time"] if newest else None
    posted = set()
    if last_ms is not None:
        posted = {a["text"] for a in request(
            f"{GRAFANA}/api/annotations?tags=proxmox&from={last_ms}&to={last_ms}&limit=1000", token)}
    now_ns = time.time_ns()
    start_ns = last_ms * 10**6 if last_ms is not None else now_ns - BACKFILL_NS
    params = urllib.parse.urlencode({"query": QUERY, "start": start_ns, "end": now_ns,
                                     "limit": LIMIT, "direction": "forward"})
    streams = request(f"{LOKI}/loki/api/v1/query_range?{params}")["data"]["result"]
    batch = []
    for s in streams:
        for ts, line in s["values"]:
            change = parse(line, s["stream"].get("host", "?"))
            if change:
                batch.append(annotation(change, int(ts)))
    batch.sort(key=lambda a: a["time"])
    if sum(len(s["values"]) for s in streams) >= LIMIT:
        print(f"warning: Loki returned {LIMIT} lines; the rest follow on the next run", file=sys.stderr)
    new = fresh(batch, last_ms, posted)
    for a in new:
        request(f"{GRAFANA}/api/annotations", token, a)
    print(f"{len(new)} posted, {len(batch) - len(new)} already in Grafana")


if __name__ == "__main__":
    main()
