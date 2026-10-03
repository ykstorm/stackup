#!/usr/bin/env python3
"""Check that the canary dashboard's success-rate panel runs the gate's query.

Reads `helm template` output for the demo chart (with values.dev.yaml) on
stdin, and helm/demo/dashboards/canary.json from disk. PromQL ignores
whitespace, so both sides are compared with all whitespace removed, after
the Rollout's service-name argument is substituted into the template query.

Uses only the standard library. Prints nothing and exits 0 when the queries
match; prints both queries and exits 1 when they do not.
"""
import json
import pathlib
import re
import sys

DASHBOARD = pathlib.Path(__file__).resolve().parent.parent / "helm/demo/dashboards/canary.json"


def find_doc(docs, kind):
    for doc in docs:
        if re.search(rf"^kind: {kind}\s*$", doc, re.M):
            return doc
    sys.exit(f"no {kind} in the rendered chart")


def block_after(doc, key):
    """Return the literal block that follows `key: |` in a rendered doc."""
    lines = doc.split("\n")
    for i, line in enumerate(lines):
        if line.strip() == f"{key}: |":
            indent = len(line) - len(line.lstrip())
            body = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                    break
                body.append(nxt)
            return "\n".join(body)
    sys.exit(f"no '{key}: |' block in the AnalysisTemplate")


def main():
    docs = re.split(r"^---\s*$", sys.stdin.read().replace("\r\n", "\n"), flags=re.M)

    query = block_after(find_doc(docs, "AnalysisTemplate"), "query")
    arg = re.search(r"- name: service-name\s+value: \"?([^\"\n]+)\"?", find_doc(docs, "Rollout"))
    if not arg:
        sys.exit("no service-name argument on the Rollout")
    gate = re.sub(r"\s+", "", query.replace("{{args.service-name}}", arg.group(1)))

    dashboard = json.loads(DASHBOARD.read_text(encoding="utf-8"))
    panels = [p for p in dashboard["panels"] if "canary gate" in p.get("title", "")]
    if len(panels) != 1:
        sys.exit("expected exactly one panel titled '... (the canary gate)' in canary.json")
    panel = re.sub(r"\s+", "", panels[0]["targets"][0]["expr"])

    if gate != panel:
        print(f"gate:  {gate}\npanel: {panel}")
        sys.exit(1)


if __name__ == "__main__":
    main()
