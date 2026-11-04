#!/usr/bin/env bash
# Checks pruning protection with default and custom chart namespaces. Needs Helm and PyYAML.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART=$HERE/../chart
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
total=0

DEFAULT_NAMESPACE=$(python3 - "$CHART/values.yaml" <<'END_DEFAULT'
import sys
import yaml

with open(sys.argv[1]) as stream:
    name = yaml.safe_load(stream)["namespace"]
if not isinstance(name, str) or not name:
    raise SystemExit("chart namespace default must be a non-empty string")
print(name)
END_DEFAULT
)

fail() {
  printf '   FAIL %s: %s\n' "$1" "$2"
  fails=$((fails+1))
}

check_namespace() {
  local name=$1 expected=$2
  shift 2
  total=$((total+1))
  if ! helm template ai-grid-o11y "$CHART" --set lokistack.storageClassName=test "$@" > "$T/rendered.yaml"; then
    fail "$name" "chart render failed"
    return
  fi
  if ! python3 - "$T/rendered.yaml" > "$T/namespace.yaml" <<'END_NAMESPACE'
import sys
import yaml

with open(sys.argv[1]) as stream:
    namespaces = [doc for doc in yaml.safe_load_all(stream) if doc and doc.get("kind") == "Namespace"]
if len(namespaces) != 1:
    raise SystemExit(f"expected one Namespace document, got {len(namespaces)}")
yaml.safe_dump(namespaces[0], sys.stdout)
END_NAMESPACE
  then
    fail "$name" "Namespace extraction failed"
    return
  fi
  if bash "$HERE/sync-policy-test.sh" "$T/namespace.yaml" "$expected"; then
    printf '   ok   %s\n' "$name"
  else
    fail "$name" "sync policy check failed"
  fi
}

check_namespace "default namespace" "$DEFAULT_NAMESPACE"
check_namespace "custom namespace" "test-monitoring" --set namespace=test-monitoring
echo "sync-policy chart tests: $((total-fails)) ok, $fails failed"
exit "$fails"
