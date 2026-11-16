#!/bin/bash
set -e
# Bootstrap a cluster to be managed by this repo
# Per https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/installing_gitops/installing-openshift-gitops#installing-gitops-operator-using-cli_installing-openshift-gitops
#
# BOOTSTRAP_PROFILE selects what the hub runs, by labelling
# managedcluster/local-cluster (see bootstrap/applicationset.yaml):
#   "" (default)          ai-grid/is-hub + ai-grid/is-maas-infra: full hub,
#                         including the MaaS state apps (maas-db,
#                         limitador-redis, external-secrets). The old
#                         dedicated-hub profile maps to this default.
#   hub                   ai-grid/is-hub only: management-only hub without the
#                         MaaS state apps.
#   acm-and-gitops-only   no labels: foundation install that stops at GitOps +
#                         ACM. Label local-cluster later to broaden acm and
#                         start the rest of the stack.
profile="${BOOTSTRAP_PROFILE:-}"
case "$profile" in
  ""|hub|acm-and-gitops-only) ;;
  *) echo "ERROR: unknown BOOTSTRAP_PROFILE ${profile}." >&2; exit 1 ;;
esac
oc apply -f bootstrap/namespace.yaml
oc apply -f bootstrap/gitops-operator-group.yaml
oc apply -f bootstrap/openshift-gitops-sub.yaml

echo "Waiting for OpenShift GitOps CRDs..."
wait_for_crd() {
  local crd="$1"
  for _ in $(seq 1 120); do
    # A just-created CRD has no status.conditions yet, which oc wait reports as an error.
    if oc get "customresourcedefinitions.apiextensions.k8s.io/${crd}" >/dev/null 2>&1 &&
      oc wait --for=condition=Established "customresourcedefinitions.apiextensions.k8s.io/${crd}" --timeout=1m 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: timed out waiting for CRD ${crd}." >&2
  return 1
}

wait_for_crd applications.argoproj.io
wait_for_crd applicationsets.argoproj.io

# The default Argo CD instance appears shortly after the operator's CRDs register; wait for it
# (ARGOCD_READY_TIMEOUT_SECONDS, default 600; ARGOCD_POLL_SECONDS, default 5) before applying into it.
echo "Waiting for the openshift-gitops Argo CD instance..."
wait_for_argocd() {
  timeout="${ARGOCD_READY_TIMEOUT_SECONDS:-600}"
  poll="${ARGOCD_POLL_SECONDS:-5}"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    request_timeout=30; [ "$request_timeout" -gt "$remaining" ] && request_timeout=$remaining
    if phase=$(oc --request-timeout="${request_timeout}s" -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null) \
      && [ "$phase" = Available ] && [ "$SECONDS" -lt "$deadline" ]; then
      return 0
    fi
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
  echo "ERROR: argocd/openshift-gitops not Available after ${timeout}s; set ARGOCD_READY_TIMEOUT_SECONDS to wait longer." >&2
  return 1
}
wait_for_argocd

oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Break the ACM deadlock: the root ApplicationSet's clusters generators can only
# match local-cluster after ACM surfaces its Argo CD cluster secret, so the
# appset alone can never install ACM. Apply ACM's namespace and the minimum
# resources by hand — the same files the generated acm Application syncs — and
# let that Application adopt them afterwards.
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
EOF
oc apply -f apps/acm/manifests/core/operator-group.yaml
oc apply -f apps/acm/manifests/core/subscription.yaml
oc apply -f apps/acm/manifests/core/multiclusterhub.yaml

# Wait for health: the ACM Subscription's CSV (MCH_READY_TIMEOUT_SECONDS,
# default 900; ARGOCD_POLL_SECONDS, default 5), then MultiClusterHub Available.
echo "Waiting for the ACM operator..."
wait_for_acm_csv() {
  timeout="${MCH_READY_TIMEOUT_SECONDS:-900}"
  poll="${ARGOCD_POLL_SECONDS:-5}"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    request_timeout=30; [ "$request_timeout" -gt "$remaining" ] && request_timeout=$remaining
    if csv=$(oc --request-timeout="${request_timeout}s" -n open-cluster-management get clusterserviceversions.operators.coreos.com -o name 2>/dev/null | grep -m1 advanced-cluster-management) \
      && [ -n "$csv" ] \
      && oc --request-timeout="${request_timeout}s" -n open-cluster-management wait --for=condition=Succeeded "$csv" --timeout="${request_timeout}s" 2>/dev/null \
      && [ "$SECONDS" -lt "$deadline" ]; then
      return 0
    fi
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
  echo "ERROR: ACM CSV not Succeeded after ${timeout}s; set MCH_READY_TIMEOUT_SECONDS to wait longer." >&2
  return 1
}
wait_for_acm_csv

echo "Waiting for the MultiClusterHub..."
wait_for_mch() {
  timeout="${MCH_READY_TIMEOUT_SECONDS:-900}"
  poll="${ARGOCD_POLL_SECONDS:-5}"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    request_timeout=30; [ "$request_timeout" -gt "$remaining" ] && request_timeout=$remaining
    if oc --request-timeout="${request_timeout}s" -n open-cluster-management wait --for=condition=Available multiclusterhub.operator.open-cluster-management.io/multiclusterhub --timeout="${request_timeout}s" 2>/dev/null \
      && [ "$SECONDS" -lt "$deadline" ]; then
      return 0
    fi
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
  echo "ERROR: multiclusterhub not Available after ${timeout}s; set MCH_READY_TIMEOUT_SECONDS to wait longer." >&2
  return 1
}
wait_for_mch

# Label the hub's ManagedCluster per the profile, before applying the appset, so
# generation is immediate. Foundation mode sets no labels.
case "$profile" in
  acm-and-gitops-only) ;;
  hub)
    oc label managedcluster local-cluster ai-grid/is-hub=true --overwrite
    ;;
  *)
    oc label managedcluster local-cluster ai-grid/is-hub=true ai-grid/is-maas-infra=true --overwrite
    ;;
esac

oc apply -f bootstrap/applicationset.yaml

if [ "$profile" = acm-and-gitops-only ]; then
  cat <<'EOF'
Foundation install complete: OpenShift GitOps, Argo CD and ACM only. The acm
Application syncs just ACM's OperatorGroup, Subscription and MultiClusterHub
until the hub is labelled.

To turn it into a full hub, label local-cluster and let the root ApplicationSet
generate the rest:

  oc label managedcluster local-cluster ai-grid/is-hub=true ai-grid/is-maas-infra=true

For a management-only hub without the MaaS state apps, label ai-grid/is-hub=true
alone. Set the Quay pull secret (RHOAI_QUAY_PULL_SECRET, RHOAI_STAGE_PULL_SECRET)
before broadening a hub to run the stack.
EOF
  exit 0
fi

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
