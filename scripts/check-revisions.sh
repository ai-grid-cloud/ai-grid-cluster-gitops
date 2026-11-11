#!/usr/bin/env bash
# Check that every Argo CD Application on the hub that reads the library runs
# the deployment's pinned commit (libraryRevision), including the Applications
# that nested ApplicationSets generate for the sites. Read only.
#
# Usage: scripts/check-revisions.sh --deployment DIR [--kubeconfig PATH]   (exit 1 on any offender)
set -Eeuo pipefail
dir="" args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --deployment) dir=$2; shift 2 ;;
    --kubeconfig) args=(--kubeconfig "$2"); shift 2 ;;
    *) echo "Usage: check-revisions.sh --deployment DIR [--kubeconfig PATH]" >&2; exit 2 ;;
  esac
done
[ -d "$dir/root" ] || { echo "--deployment must be a checkout with root/" >&2; exit 2; }
. "$(dirname "$0")/deployment-inputs.sh"
deployment_render "$dir"
repo="$(deployment_input libraryRepoURL)" sha="$(deployment_input libraryRevision)"
oc "${args[@]}" get applications.argoproj.io -n openshift-gitops -o json | python3 -c '
import json, sys
repo, sha = sys.argv[1].removesuffix(".git"), sys.argv[2]
checked = bad = 0
for a in json.load(sys.stdin)["items"]:
    spec, st = a["spec"], a.get("status", {}).get("sync", {})
    sources = spec.get("sources") or [spec.get("source", {})]
    revs = st.get("revisions") or [st.get("revision")]
    for i, s in enumerate(sources):
        if s.get("repoURL", "").removesuffix(".git") != repo:
            continue
        checked += 1
        got = revs[i] if i < len(revs) else None
        if s.get("targetRevision") != sha or got != sha:
            bad += 1
            print("OFF ", a["metadata"]["name"], "source", i, "targetRevision=%s synced=%s" % (s.get("targetRevision"), got))
print(f"{checked} library sources checked, {bad} not at {sha[:7]}")
sys.exit(1 if bad or not checked else 0)
' "$repo" "$sha"
