#!/bin/bash
set -e
# Bootstrap a cluster to be managed by this repo
# Per https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/installing_gitops/installing-openshift-gitops#installing-gitops-operator-using-cli_installing-openshift-gitops
# BOOTSTRAP_PROFILE=dedicated-hub installs a hub that runs no Grid or RHOAI workloads.
profile="${BOOTSTRAP_PROFILE:-}"
case "$profile" in
  ""|dedicated-hub) ;;
  *) echo "ERROR: unknown BOOTSTRAP_PROFILE ${profile}." >&2; exit 1 ;;
esac

# The root ApplicationSet with the deployment repository filled in. A deployment
# keeps its per-cluster values in a repository of its own (docs/acm/hub-onboarding):
# DEPLOYMENT_REPO_URL, DEPLOYMENT_REVISION and DEPLOYMENT_PATH replace the value on
# each line of the file marked "# DEPLOYMENT_<NAME>". Unset, the file's own values
# stay: this repository at HEAD and a path it doesn't have, so nothing is read.
root_applicationset() {
  local file=$1 line name value head old tail out="" re='^(.*: )([^ ]+)( # (DEPLOYMENT_[A-Z_]+))$'
  local DEPLOYMENT_PATH=${DEPLOYMENT_PATH:-}
  DEPLOYMENT_PATH=${DEPLOYMENT_PATH#/}; DEPLOYMENT_PATH=${DEPLOYMENT_PATH%/}
  for name in DEPLOYMENT_REPO_URL DEPLOYMENT_REVISION DEPLOYMENT_PATH; do
    case ${!name:-} in
      *[[:space:]\"\\#]*) echo "ERROR: ${name} can't contain whitespace, \", \\ or #." >&2; return 1 ;;
    esac
    if [ -n "${!name:-}" ] && ! grep -q " # ${name}\$" "$file"; then
      echo "ERROR: ${name} is set, but ${file} has no line marked # ${name}." >&2; return 1
    fi
  done
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re ]]; then
      name=${BASH_REMATCH[4]} head=${BASH_REMATCH[1]} old=${BASH_REMATCH[2]} tail=${BASH_REMATCH[3]}
      value=${!name:-}
      # The deployment apps generator's path keeps its /apps/*.yaml.
      [[ -n $value && $name == DEPLOYMENT_PATH && $old == */apps/\*.yaml ]] && value+=/apps/*.yaml
      [ -n "$value" ] && line=$head$value$tail
    fi
    out+=$line$'\n'
  done < "$file"
  printf '%s' "$out"
}
root=$(root_applicationset "bootstrap/${profile:+${profile}/}applicationset.yaml")

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

printf '%s' "$root" | oc apply -f -
oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
