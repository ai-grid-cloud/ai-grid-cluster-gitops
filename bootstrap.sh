#!/bin/bash
set -e
# Bootstrap a cluster to be managed by this repo
# Per https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/installing_gitops/installing-openshift-gitops#installing-gitops-operator-using-cli_installing-openshift-gitops
oc apply -f bootstrap/namespace.yaml
oc apply -f bootstrap/gitops-operator-group.yaml
oc apply -f bootstrap/openshift-gitops-sub.yaml

echo "Waiting for OpenShift GitOps CRDs..."
wait_for_crd() {
  local crd="$1"
  for _ in $(seq 1 120); do
    if oc get "customresourcedefinitions.apiextensions.k8s.io/${crd}" >/dev/null 2>&1; then
      oc wait --for=condition=Established "customresourcedefinitions.apiextensions.k8s.io/${crd}" --timeout=1m
      return 0
    fi
    sleep 5
  done
  echo "ERROR: timed out waiting for CRD ${crd}." >&2
  return 1
}

wait_for_crd applications.argoproj.io
wait_for_crd applicationsets.argoproj.io

# The deployment repository holds this deployment's cluster values, hostnames
# and hub objects (layout: deployment/README.md). By default it's this
# repository's own deployment/ directory.
: "${DEPLOYMENT_REPO_URL:=https://github.com/kahowell/ai-grid-tenant.git}"
: "${DEPLOYMENT_REVISION:=HEAD}"
: "${DEPLOYMENT_PATH:=deployment}"
# The values land inside a Go template string, so a quote or backslash would
# break it.
for v in "$DEPLOYMENT_REPO_URL" "$DEPLOYMENT_REVISION" "$DEPLOYMENT_PATH"; do
  case $v in *'"'* | *'\'*) echo "ERROR: DEPLOYMENT_* values can't contain \" or \\: $v" >&2; exit 1 ;; esac
done
# Rerun this script whenever the root ApplicationSet changes: nothing else
# applies it. Quoted replacements, so bash 5.2+ doesn't expand & in them.
root=$(<bootstrap/applicationset.yaml)
root=${root//'${DEPLOYMENT_REPO_URL}'/"$DEPLOYMENT_REPO_URL"}
root=${root//'${DEPLOYMENT_REVISION}'/"$DEPLOYMENT_REVISION"}
root=${root//'${DEPLOYMENT_PATH}'/"$DEPLOYMENT_PATH"}
printf '%s\n' "$root" | oc apply -f -
oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
