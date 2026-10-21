#!/usr/bin/env python3
"""Fail when an Alloy metric drop rule removes a series a dashboard reads.

  drop_guard.py --dashboards <dir> --alloy <file> [<file> ...]

Walks <dir>/**/*.json, collects every Prometheus target expression (nested
panels and rows included), and fullmatches each metric name against the
`regex` of every `rule { source_labels = ["__name__"]  action = "drop" }`
in the Alloy files. Exit 1 and one line per conflict, otherwise 0.
"""
import argparse
import json
import re
import sys
from pathlib import Path

KEYWORDS = {"and", "or", "unless", "bool", "offset", "by", "without", "on", "ignoring",
            "group_left", "group_right", "inf", "nan", "start", "end"}
STRING = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`[^`]*`')
LABEL_BLOCK = re.compile(r"\{[^{}]*\}")
RANGE = re.compile(r"\[[^\[\]]*\]")
GROUPING = re.compile(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)")
TEMPLATE_VAR = re.compile(r"\$\{[^}]*\}|\$\w+")
IDENT = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*(?!\w)(?!\s*\()")
RULE_BLOCK = re.compile(r"\brule\s*\{([^{}]*)\}")
RIVER_STRING = re.compile(r'(\w+)\s*=\s*("(?:\\.|[^"\\])*")')


def metric_names(expr):
    for pattern in (STRING, TEMPLATE_VAR, RANGE, LABEL_BLOCK, GROUPING):
        expr = pattern.sub(" ", expr)
    return {m for m in IDENT.findall(expr) if m not in KEYWORDS}


def drop_regexes(river):
    regexes = []
    for body in RULE_BLOCK.findall(river):
        attrs = dict(RIVER_STRING.findall(body))
        list_match = re.search(r"source_labels\s*=\s*(\[[^\]]*\])", body)
        if (list_match and json.loads(list_match.group(1)) == ["__name__"]
                and attrs.get("action") == '"drop"' and "regex" in attrs):
            regexes.append(json.loads(attrs["regex"]))
    return regexes


def conflicts(names, regexes):
    return [(n, r) for n in sorted(names) for r in regexes if re.fullmatch(r, n)]


def targets(node):
    if isinstance(node, dict):
        ds = node.get("datasource")
        is_loki = isinstance(ds, dict) and ds.get("uid") == "loki"
        for t in node.get("targets") or []:
            tds = t.get("datasource")
            if t.get("expr") and not is_loki and not (isinstance(tds, dict) and tds.get("uid") == "loki"):
                yield t["expr"]
        for v in node.values():
            yield from targets(v)
    elif isinstance(node, list):
        for v in node:
            yield from targets(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dashboards", required=True, type=Path)
    ap.add_argument("--alloy", required=True, nargs="+", type=Path)
    args = ap.parse_args()

    names = {}
    for path in sorted(args.dashboards.rglob("*.json")):
        for expr in targets(json.loads(path.read_text())):
            for n in metric_names(expr):
                names.setdefault(n, path)
    regexes = [r for f in args.alloy for r in drop_regexes(f.read_text())]

    found = conflicts(set(names), regexes)
    for name, regex in found:
        print(f"{names[name]}: reads {name}, dropped by regex {regex!r}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
