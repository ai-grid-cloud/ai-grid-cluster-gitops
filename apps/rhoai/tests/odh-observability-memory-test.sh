#!/usr/bin/env bash
# Renders the odh-observability memory policy and checks its ApplicationSet wiring.
# Needs helm and PyYAML.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if helm template rhoai-odh-observability-memory "$HERE/../odh-observability-memory" \
  > /dev/null 2>&1; then
  echo "expected the chart to require clusterNamespace" >&2
  exit 1
fi

helm template rhoai-odh-observability-memory "$HERE/../odh-observability-memory" \
  --set clusterNamespace=target-cluster > "$TMP_DIR/rendered.yaml"

python3 - "$TMP_DIR/rendered.yaml" "$HERE/../hub/01-applicationset.yaml" <<'PY'
import sys
import yaml

rendered_documents = [document for document in yaml.safe_load_all(open(sys.argv[1])) if document]
assert len(rendered_documents) == 1, rendered_documents
policy = rendered_documents[0]
assert policy["kind"] == "ConfigurationPolicy"
assert policy["metadata"]["namespace"] == "target-cluster"
assert policy["spec"]["remediationAction"] == "enforce"
template = policy["spec"]["object-templates"][0]
assert template["complianceType"] == "musthave"
deployment = template["objectDefinition"]
assert deployment["kind"] == "Deployment"
assert deployment["metadata"] == {"name": "odh-observability",
                                  "namespace": "redhat-ods-applications"}
containers = deployment["spec"]["template"]["spec"]["containers"]
assert containers == [{
    "name": "manager",
    "resources": {"requests": {"memory": "2Gi"}, "limits": {"memory": "3Gi"}},
}], containers

appset = yaml.safe_load(open(sys.argv[2]))
sources = appset["spec"]["template"]["spec"]["sources"]
source = next(item for item in sources
              if item.get("path") == "apps/rhoai/odh-observability-memory")
parameters = {parameter["name"]: parameter["value"]
              for parameter in source["helm"]["parameters"]}
assert parameters == {"clusterNamespace": "{{ .name }}"}
PY

echo "odh-observability-memory tests: 1 ok, 0 failed"
