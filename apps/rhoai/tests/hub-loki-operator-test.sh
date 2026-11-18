#!/usr/bin/env bash
# A cluster labelled ai-grid/hub-loki-operator=true (an all-in-one, whose hub app ai-grid-usage-logs installs the Loki
# operator) must not get the operator from the site's rhoai chart too; any other cluster renders exactly as before.
# Renders the dependencies.loki.enabled parameter (extracted from the ApplicationSet) per label context, then the pinned
# chart with each value. RHAI_CHART_DIR skips the OCI pull. Needs helm, PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/chart/templates"; fails=0; total=0
APPSET=$HERE/../hub/01-applicationset.yaml
ok() { total=$((total+1)); printf '   ok   %-56s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-56s %s\n' "$1" "${2:-}"; }
python3 -c 'import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); param = None; chart = None
for s in d["spec"]["template"]["spec"]["sources"]:
    for p in (s.get("helm") or {}).get("parameters", []):
        if p["name"] == "dependencies.loki.enabled": param = p["value"]
    if s.get("repoURL", "").startswith("oci://") and s.get("path") == ".": chart = {"repoURL": s["repoURL"], "targetRevision": s["targetRevision"]}
json.dump({"param": param, "chart": chart}, open(sys.argv[2], "w"))' "$APPSET" "$T/appset.json"
param_present=$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1]))["param"] else "no")' "$T/appset.json")
if [ "$param_present" = yes ]; then ok "ApplicationSet sets dependencies.loki.enabled"; else bad "ApplicationSet sets dependencies.loki.enabled" "absent"; echo "hub-loki-operator tests: $((total-fails)) ok, $fails failed"; exit 1; fi

# Part one: the parameter's value per label context, through the same templating Argo CD uses.
printf 'apiVersion: v2\nname: p\nversion: 0.1.0\n' > "$T/chart/Chart.yaml"
cat > "$T/chart/templates/out.yaml" <<'END_TPL'
loki: "{{ tpl .Values.param (dict "metadata" (dict "labels" .Values.labels)) }}"
END_TPL
value_for() { # labels-json -> rendered parameter value
  python3 -c 'import json,sys; json.dump({"param": json.load(open(sys.argv[1]))["param"], "labels": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))' "$T/appset.json" "$1" "$T/v.json"
  helm template x "$T/chart" -f "$T/v.json" | sed -n 's/^loki: "\(.*\)"$/\1/p'; }
t() { local name=$1 want=$2 labels=$3 got; got=$(value_for "$labels")
  if [ "$got" = "$want" ]; then ok "$name" "enabled=$want"; else bad "$name" "got '$got' wanted $want"; fi; }
t labelled-all-in-one-skips-operator false '{"local-cluster": "true", "ai-grid/role": "combined", "ai-grid/hub-loki-operator": "true"}'
t unlabelled-hub-keeps-chart-default auto '{"local-cluster": "true", "ai-grid/role": "combined"}'
t unlabelled-spoke-keeps-chart-default auto '{"ai-grid/role": "ingress"}'
t other-label-value-keeps-chart-default auto '{"ai-grid/hub-loki-operator": "false"}'
t empty-label-value-keeps-chart-default auto '{"ai-grid/hub-loki-operator": ""}'

# Part two: the pinned chart. auto must render byte-identically to no setting; false must drop exactly the Loki
# operator's Namespace, OperatorGroup and Subscription.
read -r repo rev < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["chart"]; print(c["repoURL"], c["targetRevision"])' "$T/appset.json")
if [ -n "${RHAI_CHART_DIR:-}" ]; then CHART=$RHAI_CHART_DIR
else helm pull "$repo" --version "$rev" --destination "$T/odh-gitops" --untar; CHART=$T/odh-gitops/rhai-on-openshift-chart; fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
helm dependency build "$CHART" >/dev/null
render() { # role out [extra --set]
  local role=$1 out=$2; shift 2
  helm template rhai-on-openshift "$CHART" -f "$HERE/../values.yaml" -f "$HERE/../roles/$role.yaml" \
    --set praxis-gateway.grid.siteName=site --set praxis-provider-gateway.grid.siteName=site "$@" > "$out"; }
removed() { # base other -> sorted "Kind namespace/name" lines present in base but not in other
  python3 -c 'import sys, yaml
def ids(f): return {(d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"]) for d in yaml.safe_load_all(open(f)) if d}
for k, ns, n in sorted(ids(sys.argv[1]) - ids(sys.argv[2])): print(f"{k} {ns}/{n}")' "$1" "$2"; }
want_removed=$'Namespace /openshift-operators-redhat\nOperatorGroup openshift-operators-redhat/openshift-operators-redhat\nSubscription openshift-operators-redhat/loki-operator'
for role in combined ingress inference; do
  render "$role" "$T/$role-none.yaml"
  render "$role" "$T/$role-auto.yaml" --set dependencies.loki.enabled=auto
  render "$role" "$T/$role-false.yaml" --set dependencies.loki.enabled=false
  if cmp -s "$T/$role-none.yaml" "$T/$role-auto.yaml"; then ok "$role: unlabelled render byte-identical"; else bad "$role: unlabelled render byte-identical" "differs"; fi
  got=$(removed "$T/$role-none.yaml" "$T/$role-false.yaml")
  if [ "$got" = "$want_removed" ]; then ok "$role: label drops only the Loki operator objects"; else bad "$role: label drops only the Loki operator objects" "$(printf '%s' "$got" | paste -sd ';' -)"; fi
  # Nothing may appear only with the label.
  if [ -z "$(removed "$T/$role-false.yaml" "$T/$role-none.yaml")" ]; then ok "$role: label adds no object"; else bad "$role: label adds no object"; fi
done
echo "hub-loki-operator tests: $((total-fails)) ok, $fails failed"; exit "$fails"
