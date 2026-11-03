#!/usr/bin/env bash
# Renders apps/ai-grid-o11y/chart and asserts: the object identities (kind, namespace, name, waves, hooks) of the
# manifests the chart replaced, so Argo CD adopts them in place; the existingSecret mode (no claim, hook or
# provisioning RBAC; the LokiStack names the given Secret and CA); the required storage class; mode validation;
# the hook reading the claim's endpoint. Needs helm and python3 with PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART=$HERE/../chart; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s %s\n' "$1" "${2:-}"; }
cat > "$T/ids.py" <<'END_IDS'
import sys, yaml
rows = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    a = d["metadata"].get("annotations") or {}
    rows.append("|".join([d["kind"], d["metadata"].get("namespace", ""), d["metadata"].get("name") or "generateName:" + d["metadata"]["generateName"], a.get("argocd.argoproj.io/sync-wave", ""), a.get("argocd.argoproj.io/hook", "")]))
print("\n".join(sorted(rows)))
END_IDS
cat > "$T/fields.py" <<'END_FIELDS'
import sys, yaml
docs = {(d["kind"], d["metadata"].get("name")): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
ls = docs[("LokiStack", "usage-logs")]["spec"]
job = [d for (k, n), d in docs.items() if k == "Job"]
script = job[0]["spec"]["template"]["spec"]["containers"][0]["args"][0] if job else ""
print("size=%s days=%s class=%s secret=%s tls=%s job=%s image=%s obc=%s provision_rbac=%s endpoint_from_claim=%s" % (
    ls["size"], ls["limits"]["global"]["retention"]["days"], ls["storageClassName"], ls["storage"]["secret"]["name"], (ls["storage"].get("tls") or {}).get("caName", "none"),
    len(job), job[0]["spec"]["template"]["spec"]["containers"][0]["image"] if job else "-", len([1 for (k, n) in docs if k == "ObjectBucketClaim"]),
    len([1 for (k, n) in docs if n == "provision-loki-key"]), "BUCKET_HOST" in script and "BUCKET_PORT" in script and "s3.openshift-storage.svc" not in script))
END_FIELDS
render() { helm template ai-grid-o11y "$CHART" "$@" 2>&1; }
render --set lokistack.storageClassName=standard > "$T/obc.yaml"; python3 "$T/ids.py" "$T/obc.yaml" > "$T/ids.txt"
if diff -u "$HERE/identities.txt" "$T/ids.txt" > "$T/ids.diff"; then ok "obc mode renders the 18 identities the manifests had"; else bad "obc mode renders the 18 identities the manifests had" "$(grep -E '^[-+][^-+]' "$T/ids.diff" | head -4 | tr '\n' ' ')"; fi
f=$(python3 "$T/fields.py" "$T/obc.yaml")
if [ "$f" = "size=1x.demo days=30 class=standard secret=usage-logs-object-storage tls=openshift-service-ca-bundle job=1 image=registry.redhat.io/openshift4/ose-cli:latest obc=1 provision_rbac=3 endpoint_from_claim=True" ]; then ok "obc mode: defaults, service CA, hook with the claim's endpoint"; else bad "obc mode: defaults, service CA, hook with the claim's endpoint" "$f"; fi
render --set lokistack.storageClassName=fast --set lokistack.size=1x.small --set lokistack.retentionDays=7 --set job.image=registry.example.com/cli@sha256:0000 > "$T/opts.yaml"; f=$(python3 "$T/fields.py" "$T/opts.yaml")
if [ "$f" = "size=1x.small days=7 class=fast secret=usage-logs-object-storage tls=openshift-service-ca-bundle job=1 image=registry.example.com/cli@sha256:0000 obc=1 provision_rbac=3 endpoint_from_claim=True" ]; then ok "class, size, retention and image are inputs"; else bad "class, size, retention and image are inputs" "$f"; fi
render --set lokistack.storageClassName=standard --set objectStorage.mode=existingSecret --set objectStorage.existingSecret.name=my-s3 > "$T/ext.yaml"; f=$(python3 "$T/fields.py" "$T/ext.yaml")
if [ "$f" = "size=1x.demo days=30 class=standard secret=my-s3 tls=none job=0 image=- obc=0 provision_rbac=0 endpoint_from_claim=False" ]; then ok "existingSecret mode: no claim, hook or provisioning RBAC; the named Secret; no TLS block"; else bad "existingSecret mode" "$f"; fi
render --set lokistack.storageClassName=standard --set objectStorage.mode=existingSecret --set objectStorage.existingSecret.name=my-s3 --set objectStorage.existingSecret.caName=my-ca > "$T/ext2.yaml"
if grep -q 'caName: my-ca' "$T/ext2.yaml"; then ok "existingSecret mode: a CA ConfigMap can be named"; else bad "existingSecret mode: a CA ConfigMap can be named"; fi
out=$(render 2>&1 || true); if grep -q 'lokistack.storageClassName is required' <<<"$out"; then ok "no storage class: render refused"; else bad "no storage class: render refused" "$(tail -1 <<<"$out")"; fi
out=$(render --set lokistack.storageClassName=standard --set objectStorage.mode=existingSecret 2>&1 || true); if grep -q 'existingSecret.name is required' <<<"$out"; then ok "existingSecret mode without a name: refused"; else bad "existingSecret mode without a name: refused"; fi
out=$(render --set lokistack.storageClassName=standard --set objectStorage.mode=nfs 2>&1 || true); if grep -q 'use obc or existingSecret' <<<"$out"; then ok "unknown mode: refused"; else bad "unknown mode: refused"; fi
if grep -q 'namespace: other-ns' <(render --set lokistack.storageClassName=standard --set namespace=other-ns | grep -A3 'kind: PersesDashboard'); then ok "dashboard follows the namespace"; else bad "dashboard follows the namespace"; fi
render --set lokistack.storageClassName=standard --set namespace=other-ns > "$T/ns.yaml"
cat > "$T/misc.py" <<'END_MISC'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
by = {(d["kind"], d["metadata"].get("name")): d for d in docs}
sc = by[("ScrapeConfig", "rhai-metrics")]; np = by[("NetworkPolicy", "allow-acm-rhai-metrics")]
print("collector_target=%s np_ns=%s" % (sc["spec"]["staticConfigs"][0]["targets"][0].split(".")[1], np["metadata"]["namespace"]))
ann = lambda k, n: (by[(k, n)]["metadata"].get("annotations") or {}).get("argocd.argoproj.io/sync-options", "")
print("obc_opts=%s ns_opts=%s" % (ann("ObjectBucketClaim", "usage-logs-bucket"), ann("Namespace", "other-ns")))
job = [d for (k, n), d in by.items() if k == "Job"][0]; c = job["spec"]["template"]["spec"]["containers"][0]
print("verify=%s mount=%s" % ("--cacert /etc/bucket-ca/service-ca.crt" in c["args"][0], any(m["mountPath"] == "/etc/bucket-ca" for m in c.get("volumeMounts", []))))
END_MISC
f=$(python3 "$T/misc.py" "$T/ns.yaml" | tr '\n' ' ')
if [ "$f" = "collector_target=redhat-ods-monitoring np_ns=redhat-ods-monitoring obc_opts=Prune=false,Delete=false ns_opts=Prune=false,Delete=false verify=True mount=True " ]; then ok "collector stays in RHOAI's namespace; claim and namespace never pruned; hook verifies TLS with the CA mounted"; else bad "collector/pruning/TLS" "$f"; fi
render --set lokistack.storageClassName=standard --set objectStorage.obc.scheme=http > "$T/http.yaml"
if grep -q 'ENDPOINT="http://' "$T/http.yaml" && ! grep -q 'bucket-ca' "$T/http.yaml"; then ok "http scheme: plain endpoint, no CA mount"; else bad "http scheme: plain endpoint, no CA mount"; fi
out=$(render --set lokistack.storageClassName=standard --set objectStorage.obc.scheme=ftp 2>&1 || true); if grep -q 'use https or http' <<<"$out"; then ok "unknown scheme: refused"; else bad "unknown scheme: refused"; fi
echo "chart render tests: $((total-fails)) ok, $fails failed"; exit "$fails"
