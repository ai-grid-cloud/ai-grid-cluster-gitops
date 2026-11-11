#!/usr/bin/env bash
# Tests for scripts/check-deployment.sh and bootstrap-hub.sh's pin check,
# against a fixture deployment that takes this checkout's bootstrap/hub.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
LIB=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SHA=0123456789abcdef0123456789abcdef01234567

fixture() { # name -> a deployment dir; the root sets every input
  local d="$T/$1"; mkdir -p "$d/root" "$d/apps"
  cat > "$d/root/self.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: deployment-root, namespace: openshift-gitops}
spec:
  project: default
  source: {repoURL: https://git.example.com/acme/deployment.git, targetRevision: main, path: root}
  destination: {server: https://kubernetes.default.svc, namespace: openshift-gitops}
YAML
  cat > "$d/root/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$LIB/bootstrap/hub" "$d/root")
  - self.yaml
patches:
  - target: {group: argoproj.io, kind: ApplicationSet, name: apps}
    patch: |
      - {op: replace, path: /spec/generators/0/git/repoURL, value: https://git.example.com/acme/library.git}
      - {op: replace, path: /spec/generators/0/git/revision, value: $SHA}
      - op: replace
        path: /spec/generators/0/git/values
        value: &inputs
          libraryRepoURL: https://git.example.com/acme/library.git
          libraryRevision: $SHA
          deploymentRepoURL: &deploymentRepoURL https://git.example.com/acme/deployment.git
          deploymentRevision: &deploymentRevision main
          catalogRepoURL: https://git.example.com/acme/catalog.git
          catalogRevision: main
          idpIssuerURL: https://idp.example.com/realms/tenants
          idpClientID: tenants
          idpClientSecretNamespace: idp-client
          idpClientSecretName: idp-client
          idpClientSecretKey: client-secret
          idpCANamespace: openshift-config-managed
          idpCAName: default-ingress-cert
          idpCAKey: ca-bundle.crt
      - {op: remove, path: /spec/generators/1}
      - op: add
        path: /spec/generators/-
        value:
          git:
            repoURL: *deploymentRepoURL
            revision: *deploymentRevision
            files: [{path: apps/*.yaml}]
            values: *inputs
YAML
  echo "$d"
}

t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

d=$(fixture good)
t "a complete deployment passes" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"

d=$(fixture own-app-token)
printf 'spec:\n  source:\n    repoURL: '"'"'@deploymentRepoURL@'"'"'\n' > "$d/apps/idp.yaml"
t "an own app using @deploymentRepoURL@ passes" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"

d=$(fixture copied-app)
printf 'spec:\n  source:\n    repoURL: https://github.com/someone/example-deployment.git\n' > "$d/apps/idp.yaml"
t "an own app left pointing at the copied repository fails" 1 "someone/example-deployment" bash scripts/check-deployment.sh "$d"

d=$(fixture copied-self)
sed -i.bak 's#https://git.example.com/acme/deployment.git, targetRevision#https://github.com/someone/example-deployment.git, targetRevision#' "$d/root/self.yaml"
t "self.yaml left pointing at the copied repository fails" 1 "someone/example-deployment" bash scripts/check-deployment.sh "$d"

d=$(fixture unset)
sed -i.bak '/idpCAKey: ca-bundle.crt/d' "$d/root/kustomization.yaml"
t "an input missing from values fails" 1 "unset inputs: idpCAKey" bash scripts/check-deployment.sh "$d"

t "no root/ is a usage error" 2 "Usage" bash scripts/check-deployment.sh "$T/nothing"

d=$(fixture pin)
t "bootstrap-hub refuses a library checkout off the pin" 1 "isn't at the deployment's libraryRevision $SHA" \
  env RHOAI_QUAY_AUTH_FILE=/dev/null bash -c 'f=$(mktemp); echo {} > "$f"; RHOAI_QUAY_AUTH_FILE=$f bash scripts/bootstrap-hub.sh --deployment "$0"' "$d"

# check-revisions.sh against a stub oc that prints two Applications.
mkdir -p "$T/bin"
apps() { # rev-of-second-app
  cat <<JSON
{"items":[
 {"metadata":{"name":"acm"},"spec":{"source":{"repoURL":"https://git.example.com/acme/library","targetRevision":"$SHA"}},"status":{"sync":{"revision":"$SHA"}}},
 {"metadata":{"name":"rhoai-site"},"spec":{"source":{"repoURL":"https://git.example.com/acme/library.git","targetRevision":"$1"}},"status":{"sync":{"revision":"$1"}}},
 {"metadata":{"name":"tenant-idp"},"spec":{"source":{"repoURL":"https://git.example.com/acme/deployment.git","targetRevision":"main"}},"status":{"sync":{"revision":"abc"}}}]}
JSON
}
d=$(fixture revisions)
apps "$SHA" > "$T/apps.json"; printf '#!/bin/sh\ncat "%s"\n' "$T/apps.json" > "$T/bin/oc"; chmod +x "$T/bin/oc"
t "every library source on the pin" 0 "2 library sources checked, 0 not at 0123456" env PATH="$T/bin:$PATH" bash scripts/check-revisions.sh --deployment "$d"
apps "fedcba9876543210fedcba9876543210fedcba98" > "$T/apps.json"
t "a source off the pin is named" 1 "OFF  rhoai-site" env PATH="$T/bin:$PATH" bash scripts/check-revisions.sh --deployment "$d"

echo "deployment-scripts tests: $((total-fails)) ok, $fails failed"; exit "$fails"
