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


def label_values_selector(expr):
    """Replace each `label_values(<selector>, <label>)` by its selector; a bare `label_values(<label>)` reads no metric."""
    out = []
    i = 0
    while True:
        j = expr.find("label_values(", i)
        if j < 0:
            return "".join(out) + expr[i:]
        start = j + len("label_values(")
        depth, last_comma, k = 1, None, start
        while k < len(expr) and depth:
            c = expr[k]
            depth += c in "({[" 
            depth -= c in ")}]"
            if c == "," and depth == 1:
                last_comma = k
            k += 1
        out.append(expr[i:j] + " ")
        if last_comma is not None:
            out.append(expr[start:last_comma])
        i = k


def metric_names(expr):
    expr = STRING.sub(" ", expr)
    expr = label_values_selector(expr)
    for pattern in (TEMPLATE_VAR, RANGE, LABEL_BLOCK, GROUPING):
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


def is_loki(datasource):
    return datasource == "loki" or (isinstance(datasource, dict) and datasource.get("uid") == "loki")


def targets(node):
    if isinstance(node, dict):
        for t in node.get("targets") or []:
            if t.get("expr") and not is_loki(t.get("datasource")) and not is_loki(node.get("datasource")):
                yield t["expr"]
        for v in node.values():
            yield from targets(v)
    elif isinstance(node, list):
        for v in node:
            yield from targets(v)


def variable_and_annotation_exprs(dashboard):
    for var in dashboard.get("templating", {}).get("list") or []:
        if var.get("type") != "query" or is_loki(var.get("datasource")):
            continue
        query = var.get("query")
        for text in (query.get("query") if isinstance(query, dict) else query, var.get("definition")):
            if isinstance(text, str):
                yield text
    for ann in dashboard.get("annotations", {}).get("list") or []:
        if is_loki(ann.get("datasource")):
            continue
        for text in (ann.get("expr"), (ann.get("target") or {}).get("expr")):
            if isinstance(text, str):
                yield text


def collect(dashboard):
    """Every Prometheus metric a dashboard reads: panel targets, variable queries, annotations."""
    exprs = list(targets(dashboard)) + list(variable_and_annotation_exprs(dashboard))
    return {n for e in exprs for n in metric_names(e)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dashboards", required=True, type=Path)
    ap.add_argument("--alloy", required=True, nargs="+", type=Path)
    args = ap.parse_args()

    names = {}
    for path in sorted(args.dashboards.rglob("*.json")):
        for n in collect(json.loads(path.read_text())):
            names.setdefault(n, path)
    regexes = [r for f in args.alloy for r in drop_regexes(f.read_text())]

    found = conflicts(set(names), regexes)
    for name, regex in found:
        print(f"{names[name]}: reads {name}, dropped by regex {regex!r}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
