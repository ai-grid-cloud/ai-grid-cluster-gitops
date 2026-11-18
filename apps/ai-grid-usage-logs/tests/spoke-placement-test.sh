#!/usr/bin/env bash
# Renders the usage-logs spoke Placement from this app's values and the ai-grid-o11y-hub chart the Application
# tracks (odh-gitops main), then evaluates its cluster selector against label sets: an ingress or combined site is
# selected, local-cluster included when it is a site (an all-in-one); a dedicated hub with no role, and an
# inference-only site, are not. ODH_GITOPS_DIR skips the clone. Needs helm, git, PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %-52s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-52s %s\n' "$1" "${2:-}"; }
read -r repo rev path < <(python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = [s for s in d["spec"]["sources"] if s.get("path", "").endswith("/ai-grid-o11y-hub")]
assert len(s) == 1, s; print(s[0]["repoURL"], s[0]["targetRevision"], s[0]["path"])' "$HERE/../application.yaml")
if [ -n "${ODH_GITOPS_DIR:-}" ]; then SRC=$ODH_GITOPS_DIR
else git clone -q --depth 1 --branch "$rev" "$repo" "$T/odh-gitops"; SRC=$T/odh-gitops; fi
[ -f "$SRC/$path/Chart.yaml" ] || { echo "chart not found at $SRC/$path" >&2; exit 1; }
helm template ai-grid-usage-logs "$SRC/$path" -f "$HERE/../values.yaml" > "$T/out.yaml"
t() { # name want(yes|no) labels-json
  local got; got=$(python3 -c 'import sys, yaml, json
labels = json.loads(sys.argv[2])
p = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Placement"]
assert len(p) == 1, len(p)
def match(sel):
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v: return False
    for e in sel.get("matchExpressions") or []:
        k, op = e["key"], e["operator"]
        if op == "In" and labels.get(k) not in e["values"]: return False
        if op == "NotIn" and k in labels and labels[k] in e["values"]: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True
preds = p[0]["spec"].get("predicates") or [{}]
sel = any(match(pr.get("requiredClusterSelector", {}).get("labelSelector", {})) for pr in preds)
print("yes" if sel else "no")' "$T/out.yaml" "$3")
  if [ "$got" = "$2" ]; then ok "$1" "selected=$got"; else bad "$1" "selected=$got, wanted $2"; fi; }
t "all-in-one: local-cluster with role combined" yes '{"local-cluster": "true", "ai-grid/role": "combined", "ai-grid/enabled": "true"}'
t "all-in-one: local-cluster with role ingress" yes '{"local-cluster": "true", "ai-grid/role": "ingress"}'
t "dedicated hub: local-cluster with no role" no '{"local-cluster": "true"}'
t "local-cluster with role inference" no '{"local-cluster": "true", "ai-grid/role": "inference"}'
t "spoke with role combined" yes '{"ai-grid/role": "combined"}'
t "spoke with role ingress" yes '{"ai-grid/role": "ingress"}'
t "spoke with role inference" no '{"ai-grid/role": "inference"}'
t "spoke with no role" no '{}'
echo "spoke-placement tests: $((total-fails)) ok, $fails failed"; exit "$fails"
