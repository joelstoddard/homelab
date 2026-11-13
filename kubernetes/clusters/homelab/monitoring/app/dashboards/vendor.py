#!/usr/bin/env python3
"""Vendor a Grafana dashboard into this directory with datasources pinned.

  vendor.py <Folder>/<name>.json --id <grafana.com id> [--revision N]
  vendor.py <Folder>/<name>.json --url <raw json url>

Every datasource reference that is a grafana.com import placeholder
(${DS_...}) or a bare type becomes {"type": T, "uid": "prometheus"|"loki"},
so a file works the moment the sidecar loads it. Template variables such as
$datasource are left alone; the dashboard resolves those itself.
"""
import argparse
import json
import sys
import urllib.request

UID_BY_TYPE = {"prometheus": "prometheus", "loki": "loki"}


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def pin(node, default_type):
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, str) and (ds.startswith("${DS_") or ds in UID_BY_TYPE):
            t = default_type if ds.startswith("${DS_") else ds
            node["datasource"] = {"type": t, "uid": UID_BY_TYPE[t]}
        elif isinstance(ds, dict):
            uid = ds.get("uid", "")
            t = ds.get("type", default_type)
            if isinstance(uid, str) and (uid.startswith("${DS_") or uid == "") and t in UID_BY_TYPE:
                ds["uid"] = UID_BY_TYPE[t]
        for k, v in node.items():
            if k != "datasource":
                pin(v, default_type)
    elif isinstance(node, list):
        for v in node:
            pin(v, default_type)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dest")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--id", type=int)
    src.add_argument("--url")
    p.add_argument("--revision", type=int)
    p.add_argument("--type", default="prometheus", choices=sorted(UID_BY_TYPE),
                   help="datasource type assumed for ${DS_*} placeholders")
    a = p.parse_args()

    if a.id:
        rev = a.revision or json.loads(fetch(f"https://grafana.com/api/dashboards/{a.id}"))["revision"]
        raw = fetch(f"https://grafana.com/api/dashboards/{a.id}/revisions/{rev}/download")
        source = f"https://grafana.com/grafana/dashboards/{a.id} revision {rev}"
    else:
        raw = fetch(a.url)
        source = a.url
    dash = json.loads(raw)

    # Import scaffolding: Grafana ignores it from a provisioning file, and the
    # __inputs block is what carries the ${DS_*} placeholders we just resolved.
    for k in ("__inputs", "__elements", "__requires"):
        dash.pop(k, None)
    dash["id"] = None
    pin(dash, a.type)

    with open(a.dest, "w") as f:
        json.dump(dash, f, indent=2, sort_keys=False)
        f.write("\n")
    print(f"{a.dest}: {dash.get('title')!r} uid={dash.get('uid')} from {source}")


if __name__ == "__main__":
    sys.exit(main())
