#!/usr/bin/env python3
"""Check that the canary dashboard's success-rate panel runs the gate's query.

Reads `helm template` output for the demo chart (with values.dev.yaml) on
stdin, and helm/demo/dashboards/canary.json from disk. PromQL ignores
whitespace, so both sides are compared with all whitespace removed, after
the Rollout's canary-service argument is substituted into the template query.

The gate also selects the new ReplicaSet by its pod-template-hash, which
Argo Rollouts only knows while the analysis runs. The panel cannot, so it
draws one line per hash instead: the gate's query with the hash matcher
removed and each `sum(` grouped by the hash label. The check applies the same
two changes to the gate's query before comparing.

Uses only the standard library. Prints nothing and exits 0 when the queries
match; prints both queries and exits 1 when they do not.
"""
import json
import pathlib
import re
import sys

DASHBOARD = pathlib.Path(__file__).resolve().parent.parent / "helm/demo/dashboards/canary.json"
HASH_LABEL = "rollouts_pod_template_hash"


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
    arg = re.search(r"- name: canary-service\s+value: \"?([^\"\n]+)\"?", find_doc(docs, "Rollout"))
    if not arg:
        sys.exit("no canary-service argument on the Rollout")
    gate = re.sub(r"\s+", "", query.replace("{{args.canary-service}}", arg.group(1)))
    hash_matcher = f'{HASH_LABEL}="{{{{args.canary-hash}}}}"'
    if gate.count(hash_matcher) != 2:
        sys.exit(f"the gate's query does not select {HASH_LABEL} on both sides")
    # Drop the matcher with one of the commas next to it: the one after it
    # when another matcher follows, the one before it when it comes last.
    gate = gate.replace(hash_matcher + ",", "").replace("," + hash_matcher, "")
    if hash_matcher in gate:
        sys.exit(f"could not remove the {HASH_LABEL} matcher from the gate's query")
    gate = gate.replace("sum(", f"sumby({HASH_LABEL})(")

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
