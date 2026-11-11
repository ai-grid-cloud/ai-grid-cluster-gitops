#!/usr/bin/env bash
# Check a deployment repository before you push it: its root renders, no
# input is left unset (no REQUIRED-<name> outside the root's own check), and
# every repository the root and its apps/*.yaml read is one of the three set as
# inputs (libraryRepoURL, deploymentRepoURL, catalogRepoURL) or an @input@
# token. The last check catches a URL left over from a repository you copied.
#
# Usage: scripts/check-deployment.sh DEPLOYMENT_DIR
set -Eeuo pipefail
[ $# -eq 1 ] && [ -d "$1/root" ] || { echo "Usage: check-deployment.sh DEPLOYMENT_DIR (a checkout with root/)" >&2; exit 2; }
dir=$1
. "$(dirname "$0")/deployment-inputs.sh"
deployment_render "$dir"
out=$DEPLOYMENT_ROOT
left="$(printf '%s\n' "$out" | grep -nE 'REQUIRED-[a-zA-Z]+' | grep -v 'regexFind "REQUIRED-' || true)"
[ -z "$left" ] || { echo "unset inputs:"; echo "$left"; exit 1; }
# Every input the library declares (its bootstrap/hub generator values) must
# be set: replacing the values map can drop one without leaving a marker.
lib="$(cd "$(dirname "$0")/.." && pwd)"
declared="$(kustomize build "$lib/bootstrap/hub" | sed -n 's/^ *\([a-zA-Z]*\): REQUIRED-\1$/\1/p' | sort -u)"
unset_inputs=""
for n in $declared; do
  v="$(deployment_input "$n")"
  [ -n "$v" ] && [ "$v" = "${v#REQUIRED-}" ] || unset_inputs="$unset_inputs $n"
done
[ -z "$unset_inputs" ] || { echo "unset inputs:$unset_inputs"; exit 1; }
printf '%s\n' "$out" | grep -q 'name: deployment-root' || { echo "deployment-root missing from root/"; exit 1; }

norm() { sed -e 's#\.git$##' -e 's#/$##'; }
allowed="$(for n in libraryRepoURL deploymentRepoURL catalogRepoURL; do deployment_input "$n" | norm; done)"
stray="$( { printf '%s\n' "$out"; cat "$dir"/apps/*.yaml 2>/dev/null || true; } |
  sed -n "s/^ *repoURL: *//p" | tr -d "'\"" | grep -v '^@[a-zA-Z]*@$' | norm | sort -u |
  grep -vxF -f <(printf '%s\n' "$allowed") || true)"
[ -z "$stray" ] || { echo "repositories that aren't your library, deployment or catalog input:"; echo "$stray"; exit 1; }
echo "root renders; every input is set; every repository is an input."
