#!/usr/bin/env python3
"""Run every dashboard panel query against the live cluster; report the ones with no data.

  check_panels.py [--context homelab] [--dashboards <dir>] [--namespace kube-system]

Prometheus targets run as instant queries, Loki targets (datasource uid
`loki`) as a 1 h query_range, both through the API-server proxy with
`kubectl get --raw`. Template variables become permissive values. With
--namespace, dashboards shipped as `grafana_dashboard` ConfigMaps there (the
Cilium chart's) are checked too. Prints `dashboard / panel / EMPTY|ERR` per
failing target and `N of M targets returned data`; exit 1 if any fail.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

PROM = "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query"
LOKI = "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query_range"


def substitute(expr):
    expr = re.sub(r"\$__rate_interval|\$\{__rate_interval\}|\$__interval|\$__auto|\$interval", "5m", expr)
    expr = expr.replace("$__range", "1h")
    expr = re.sub(r'(?<![|!~])=~?\s*"\$\{?\w+(?::\w+)?\}?"', '=~".*"', expr)
    return re.sub(r"\$\{\w+(?::\w+)?\}|\$[A-Za-z_]\w*", ".*", expr)


def kubectl_raw(context, path):
    out = subprocess.run(["kubectl", "--context", context, "get", "--raw", path],
                         capture_output=True, text=True)
    return None if out.returncode else json.loads(out.stdout)


def has_data(context, expr, loki):
    expr = substitute(expr)
    if loki:
        # Loki refuses a selector whose matchers can all match the empty string.
        expr = expr.replace('=~".*"', '=~".+"')
        now = time.time_ns()
        params = {"query": expr, "start": now - 3600 * 10**9, "end": now, "limit": 1}
        path = f"{LOKI}?{urllib.parse.urlencode(params)}"
    else:
        path = f"{PROM}?{urllib.parse.urlencode({'query': expr})}"
    body = kubectl_raw(context, path)
    if body is None or body.get("status") != "success":
        return "ERR"
    return "OK" if body["data"]["result"] else "EMPTY"


def panel_targets(node, inherited=None):
    """Yield (panel title, expr, is_loki) for every target, nested panels included."""
    for panel in node.get("panels") or []:
        ds = panel.get("datasource") or inherited
        for t in panel.get("targets") or []:
            tds = t.get("datasource") or ds
            if t.get("expr"):
                yield panel.get("title", "?"), t["expr"], isinstance(tds, dict) and tds.get("uid") == "loki"
        yield from panel_targets(panel, ds)


def repo_dashboards(directory):
    for path in sorted(directory.rglob("*.json")):
        yield str(path.relative_to(directory)), json.loads(path.read_text())


def chart_dashboards(context, namespace):
    out = subprocess.run(["kubectl", "--context", context, "-n", namespace, "get", "cm",
                          "-l", "grafana_dashboard", "-o", "json"],
                         capture_output=True, text=True, check=True)
    for cm in json.loads(out.stdout)["items"]:
        for fname, body in cm.get("data", {}).items():
            yield f"{namespace}/{fname}", json.loads(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--context", default="homelab")
    ap.add_argument("--dashboards", type=Path, default=Path(__file__).parent)
    ap.add_argument("--namespace")
    args = ap.parse_args()

    sources = list(repo_dashboards(args.dashboards))
    if args.namespace:
        sources += list(chart_dashboards(args.context, args.namespace))

    total = ok = 0
    for name, dash in sources:
        for title, expr, loki in panel_targets(dash):
            total += 1
            result = has_data(args.context, expr, loki)
            if result == "OK":
                ok += 1
            else:
                print(f"{name} / {title} / {result}")
    print(f"{ok} of {total} targets returned data")
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
