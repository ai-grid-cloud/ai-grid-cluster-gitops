#!/usr/bin/env bash
# Bootstrap a hub from a deployment repository (install step 1). Run it from a
# checkout of this library at the deployment's pinned commit (libraryRevision).
#
# 1. Checks the deployment (check-deployment.sh) and the hub's prerequisites.
# 2. Installs OpenShift GitOps from this library's bootstrap files.
# 3. Applies the deployment's root/ (the root ApplicationSet and
#    deployment-root). From then on Argo CD follows git; this script is not run
#    again.
# 4. Seeds the quay.io/rhoai pull secret (and the registry.stage.redhat.io
#    login, when present) that the prerequisites Policy copies to every site.
#    The credentials are read from a container auth file and never printed.
#
# Usage: KUBECONFIG=HUB_KUBECONFIG RHOAI_QUAY_AUTH_FILE=AUTH_JSON scripts/bootstrap-hub.sh --deployment DIR
set -Eeuo pipefail
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
lib="$(cd "$(dirname "$0")/.." && pwd)"
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deployment) dir=$2; shift 2 ;;
    *) die "usage: bootstrap-hub.sh --deployment DIR" ;;
  esac
done
[ -d "$dir/root" ] || die "--deployment must be a checkout with root/"
for c in oc kustomize jq git; do command -v "$c" >/dev/null || die "required command not found: $c"; done
auth_file="${RHOAI_QUAY_AUTH_FILE:-}"
[ -f "$auth_file" ] || die "set RHOAI_QUAY_AUTH_FILE to a container auth file (such as ~/.config/containers/auth.json) with a quay.io/rhoai login"

bash "$lib/scripts/check-deployment.sh" "$dir"
. "$lib/scripts/deployment-inputs.sh"
deployment_render "$dir"
sha="$(deployment_input libraryRevision)"
[ "$(git -C "$lib" rev-parse HEAD)" = "$sha" ] ||
  die "this library checkout isn't at the deployment's libraryRevision $sha: git -C $lib checkout $sha"
echo "Library at $sha."

RHOAI_QUAY_PULL_SECRET_FILE="$auth_file" bash "$lib/scripts/check-prerequisites.sh" --step hub --context "$(oc config current-context)" ||
  echo "Prerequisites incomplete before install; the ones this script installs are expected to be missing."

oc apply -f "$lib/bootstrap/namespace.yaml" -f "$lib/bootstrap/gitops-operator-group.yaml" -f "$lib/bootstrap/openshift-gitops-sub.yaml"
for crd in applications.argoproj.io applicationsets.argoproj.io; do
  for _ in $(seq 1 120); do oc get crd "$crd" >/dev/null 2>&1 && break; sleep 5; done
  oc wait --for=condition=Established "crd/$crd" --timeout=5m
done
for _ in $(seq 1 120); do
  [ "$(oc -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ] && break; sleep 5
done
oc apply -f "$lib/bootstrap/openshift-gitops-admin.yaml"
printf "%s\n" "$DEPLOYMENT_ROOT" | oc apply -f -

# Prefer a login scoped to quay.io/rhoai (a robot token). A general quay.io
# login is copied to the hub and to every site's pull secret, so using one needs
# RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1.
if ! RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io/rhoai"].auth' "$auth_file" 2>/dev/null)"; then
  [ "${RHOAI_QUAY_ALLOW_GENERIC_LOGIN:-}" = 1 ] ||
    die "no quay.io/rhoai login in $auth_file; add a robot token for quay.io/rhoai, or set RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1 to use the general quay.io login"
  RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io"].auth' "$auth_file")" || die "no quay.io login in $auth_file"
fi
export RHOAI_QUAY_PULL_SECRET
# The library's mirror sends registry.redhat.io/rhaii* (model runtimes) to
# registry.stage.redhat.io, so pass a stage login on when the auth file has one.
if RHOAI_STAGE_PULL_SECRET="$(jq -er '.auths["registry.stage.redhat.io"].auth' "$auth_file" 2>/dev/null)"; then
  export RHOAI_STAGE_PULL_SECRET
else
  unset RHOAI_STAGE_PULL_SECRET
  echo "warning: no registry.stage.redhat.io login in $auth_file; registry.redhat.io/rhaii* images won't pull on the sites" >&2
fi
bash "$lib/apps/rhoai-prerequisites/create-hub-secret.sh"
echo "Bootstrapped. Watch: oc get applications.argoproj.io -n openshift-gitops"
