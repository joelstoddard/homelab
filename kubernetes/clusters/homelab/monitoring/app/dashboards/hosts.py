#!/usr/bin/env python3
"""Render one Hosts/<host>.json per physical host from templates/host.json.

  python3 hosts.py

templates/hosts.json maps each host to its settings, e.g.
{"rumba": {"fans": false, "power": true, "rootfs": "/"}}. In the template,
"__HOST__" in any string becomes the host name and "__<KEY>__" becomes a
string setting's value; a panel carrying "homelabRequires": "<flag>" is kept
only when that boolean flag is true, and one carrying "homelabUnless": "<flag>"
only when it is false. Re-run after editing either file;
test_hosts.py fails while a committed host file is stale.
"""
import copy
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = "templates/host.json"
FEATURES = "templates/hosts.json"
HOSTS_DIR = "Hosts"
PLACEHOLDER = "__HOST__"
MARKER = "homelabRequires"
UNLESS = "homelabUnless"


def _substitute(node, values):
    if isinstance(node, dict):
        return {k: _substitute(v, values) for k, v in node.items()}
    if isinstance(node, list):
        return [_substitute(v, values) for v in node]
    if isinstance(node, str):
        for placeholder, value in values.items():
            node = node.replace(placeholder, value)
        return node
    return node


def _filter(panels, features):
    kept = []
    for p in panels:
        if MARKER in p and not features[p[MARKER]]:
            continue
        if UNLESS in p and features[p[UNLESS]]:
            continue
        p.pop(MARKER, None)
        p.pop(UNLESS, None)
        if "panels" in p:
            p["panels"] = _filter(p["panels"], features)
        kept.append(p)
    return kept


def _reflow(panels):
    """Close the vertical gaps dropped panels leave, so the file matches what Grafana draws."""
    spans = [(p["gridPos"]["y"], p["gridPos"]["y"] + p["gridPos"]["h"]) for p in panels if "gridPos" in p]
    covered = {y for top, bottom in spans for y in range(top, bottom)}
    for p in panels:
        if "gridPos" in p:
            y = p["gridPos"]["y"]
            p["gridPos"]["y"] = y - sum(1 for r in range(y) if r not in covered)
    return panels


def render(template, host, features):
    values = {PLACEHOLDER: host}
    values.update({f"__{k.upper()}__": v for k, v in features.items() if isinstance(v, str)})
    d = _substitute(copy.deepcopy(template), values)
    d["panels"] = _reflow(_filter(d.get("panels", []), features))
    d["uid"] = f"homelab-host-{host}"
    d["title"] = host.capitalize()
    return d


def dump(dashboard):
    return json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n"


def main():
    with open(os.path.join(HERE, TEMPLATE)) as f:
        template = json.load(f)
    with open(os.path.join(HERE, FEATURES)) as f:
        features = json.load(f)
    for host, flags in features.items():
        with open(os.path.join(HERE, HOSTS_DIR, f"{host}.json"), "w") as f:
            f.write(dump(render(template, host, flags)))


if __name__ == "__main__":
    main()
