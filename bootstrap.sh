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
# The catalog repository, where a provider console's git writer commits models
# and subscriptions (<deployment>/apps/acm-models.yaml). Its own value, so a
# deployment can keep it apart from the deployment values, which the writer
# must never reach. No default: unset, the catalog's apps fail to render rather
# than reading another repository. Never the deployment repository, unless
# CATALOG_IN_DEPLOYMENT_REPO=yes accepts that risk: a writer that can push the
# deployment values is cluster-admin on every cluster.
: "${CATALOG_REPO_URL:=}"
: "${CATALOG_REVISION:=HEAD}"
: "${CATALOG_IN_DEPLOYMENT_REPO:=no}"
# Compared as host/path, lowercase, without scheme, user, .git or a trailing
# slash, so git@host:org/repo and https://host/org/repo.git are the same.
repo_id() {
  local u; u=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  u=${u#*://}; u=${u#*@}; u=${u/://}; u=${u%/}; u=${u%.git}
  # A port after the host (host:22/org/repo, now host/22/org/repo) goes too.
  printf '%s' "$u" | sed -E 's#^([^/]+)/[0-9]+/#\1/#'
}
# Nor this repository: the template is applied with cluster-admin rights too.
template_url=$(sed -n 's#^ *repoURL: \(https://[^ ]*\)$#\1#p' bootstrap/applicationset.yaml | head -1)
if [ -n "$CATALOG_REPO_URL" ]; then
  if [ "$(repo_id "$CATALOG_REPO_URL")" = "$(repo_id "$template_url")" ]; then
    echo "ERROR: CATALOG_REPO_URL must not be the template repository" >&2
    exit 1
  fi
  if [ "$(repo_id "$CATALOG_REPO_URL")" = "$(repo_id "$DEPLOYMENT_REPO_URL")" ]; then
    if [ "$CATALOG_IN_DEPLOYMENT_REPO" != yes ]; then
      echo "ERROR: CATALOG_REPO_URL must not be the deployment repository: whoever can push the catalog would be" >&2
      echo "       cluster-admin. Set CATALOG_IN_DEPLOYMENT_REPO=yes to accept that, for a cluster you can rebuild." >&2
      exit 1
    fi
    echo "WARNING: the catalog is in the deployment repository; its writer token is cluster-admin" >&2
  fi
fi
# The values land inside a Go template string, so a quote or backslash would
# break it.
for v in "$DEPLOYMENT_REPO_URL" "$DEPLOYMENT_REVISION" "$DEPLOYMENT_PATH" "$CATALOG_REPO_URL" "$CATALOG_REVISION"; do
  case $v in *'"'* | *'\'*) echo "ERROR: DEPLOYMENT_* and CATALOG_* values can't contain \" or \\: $v" >&2; exit 1 ;; esac
done
# Rerun this script whenever the root ApplicationSet changes: nothing else
# applies it. Quoted replacements, so bash 5.2+ doesn't expand & in them.
root=$(<bootstrap/applicationset.yaml)
root=${root//'${DEPLOYMENT_REPO_URL}'/"$DEPLOYMENT_REPO_URL"}
root=${root//'${DEPLOYMENT_REVISION}'/"$DEPLOYMENT_REVISION"}
root=${root//'${DEPLOYMENT_PATH}'/"$DEPLOYMENT_PATH"}
root=${root//'${CATALOG_REPO_URL}'/"$CATALOG_REPO_URL"}
root=${root//'${CATALOG_REVISION}'/"$CATALOG_REVISION"}
printf '%s\n' "$root" | oc apply -f -
oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
