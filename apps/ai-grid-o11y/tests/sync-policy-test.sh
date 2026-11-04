#!/usr/bin/env bash
# Checks Application pruning and Namespace protection. Needs Python 3 and PyYAML.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if (( $# > 2 )); then
  printf 'Usage: %s [namespace-document [expected-namespace]]\n' "$0" >&2
  exit 2
fi
python3 - "$HERE/../application.yaml" "${1:-$HERE/../manifests/00-namespace.yaml}" "${2:-redhat-ods-monitoring}" <<'END_CHECK'
import sys
import yaml

fails = 0
total = 0

def check(condition, name):
    global fails, total
    total += 1
    if condition:
        print(f"   ok   {name}")
    else:
        fails += 1
        print(f"   FAIL {name}")

def options(value):
    entries = [value] if isinstance(value, str) else (value or [])
    return {option.strip() for entry in entries for option in entry.split(",") if option.strip()}

with open(sys.argv[1]) as stream:
    app = yaml.safe_load(stream)
with open(sys.argv[2]) as stream:
    namespace = yaml.safe_load(stream)

policy = app.get("spec", {}).get("syncPolicy", {})
sync_options = options(policy.get("syncOptions"))
check("PrunePropagationPolicy=background" in sync_options, "Application prunes in the background")
check("CreateNamespace=true" in sync_options, "Application still creates its destination namespace")
check(policy.get("automated", {}).get("prune") is True, "automatic pruning remains enabled")
check(namespace.get("kind") == "Namespace", "the supplied document is a Namespace")
metadata = namespace.get("metadata", {})
check(metadata.get("name") == sys.argv[3], "Namespace has the expected name")
annotations = metadata.get("annotations", {})
check({"Prune=false", "Delete=false"} <= options(annotations.get("argocd.argoproj.io/sync-options")),
      "Namespace is protected from pruning and Application deletion")
check(str(annotations.get("argocd.argoproj.io/sync-wave")) == "-1", "Namespace retains sync wave -1")
print(f"sync-policy tests: {total-fails} ok, {fails} failed")
sys.exit(fails)
END_CHECK
