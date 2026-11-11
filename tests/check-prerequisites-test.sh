#!/usr/bin/env bash
# Exercises scripts/check-prerequisites.sh against a stub oc (no cluster).
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/check-prerequisites.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"

# The stub answers from files in $STUB_DIR, in the shape the script's
# jsonpath queries print: version; storageclasses ("<name> <is-default>" per
# line); crds (one name per line); secrets ("<namespace>/<name>" per line);
# keys ("<secret|configmap> <namespace>/<name>:<key>" per line, for the
# go-template key probe, which prints only "present"). A missing file is an
# empty answer.
cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
args=" $* "
d=$STUB_DIR
case "$args" in
  *" get clusterversion version "*) cat "$d/version" 2>/dev/null ;;
  *" get storageclass "*) cat "$d/storageclasses" 2>/dev/null ;;
  *" get crd "*)
    name=${args##* get crd }; name=${name%% *}
    grep -qx "$name" "$d/crds" 2>/dev/null || exit 1; echo "$name" ;;
  *" get secret "*|*" get configmap "*)
    kind=secret; [[ $args == *" get configmap "* ]] && kind=configmap
    rest=${args##* get $kind }; name=${rest%% *}; ns=${args##* -n }; ns=${ns%% *}
    if [[ $args == *go-template* ]]; then
      key=$(sed -E 's/.*index \.data "([^"]+)".*/\1/' <<<"$args")
      grep -qx "$kind $ns/$name:$key" "$d/keys" 2>/dev/null && printf present
      exit 0
    fi
    grep -qx "$ns/$name" "$d/secrets" 2>/dev/null || exit 1; echo "$name" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
END_STUB
chmod 700 "$T/bin/oc"

fails=0; total=0
CM_CRDS=$'certificates.cert-manager.io\nissuers.cert-manager.io\nclusterissuers.cert-manager.io'
RHBK_CRDS=$'keycloaks.k8s.keycloak.org\nkeycloakrealmimports.k8s.keycloak.org'

world() { # name: a fresh stub world in $T/<name>
  local w="$T/$1"; rm -rf "$w"; mkdir -p "$w"
  echo "4.22.18" > "$w/version"
  echo "gp3-csi true" > "$w/storageclasses"
  printf '%s\n' "$CM_CRDS" > "$w/crds"
  echo "$w"
}

t() { # name want_rc expect_grep world [args...]
  local name=$1 want=$2 expect=$3 w=$4; shift 4; local rc out
  total=$((total+1))
  out=$(env -i PATH="$T/bin:/usr/bin:/bin" STUB_DIR="$w" RHOAI_QUAY_PULL_SECRET_FILE="${PULL:-}" \
    bash "$SCRIPT" --context stub "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ] && grep -qE "$expect" <<<"$out"; then
    printf '   ok   %s\n' "$name"
  else
    printf '   FAIL %s (rc=%s, wanted %s; output:)\n%s\n' "$name" "$rc" "$want" "$out"; fails=$((fails+1))
  fi
}

printf 'x' > "$T/pull"
w=$(world hub-ready); echo "open-cluster-management-observability/thanos-object-storage" > "$w/secrets"
PULL="$T/pull" t "hub with everything" 0 "^OK +object storage" "$w" --step hub
w=$(world hub-bare)
PULL="" t "hub before infrastructure" 1 "^MISSING +object storage" "$w" --step hub
PULL="" t "hub names the pull-secret file" 1 "^MISSING +quay.io/rhoai pull secret" "$w" --step hub
w=$(world old); echo "4.20.5" > "$w/version"
t "spoke on 4.20" 1 "^MISSING +OpenShift 4.21" "$w" --step spoke
w=$(world no-sc); : > "$w/storageclasses"
t "spoke without a default StorageClass" 1 "^MISSING +default StorageClass" "$w" --step spoke
w=$(world spoke-ok)
t "spoke ready" 0 "^OK +default StorageClass" "$w" --step spoke
w=$(world no-cm); : > "$w/crds"
t "hub without cert-manager" 1 "^MISSING +cert-manager CRDs" "$w" --step hub
IDP=(--idp-secret tenant-idp/tenant-idp-client:client-secret --idp-ca openshift-config-managed/default-ingress-cert:ca-bundle.crt)
KEYS=$'secret tenant-idp/tenant-idp-client:client-secret\nconfigmap openshift-config-managed/default-ingress-cert:ca-bundle.crt'
# Any OIDC provider meets the contract: no Keycloak or RHBK CRDs required.
w=$(world own-idp); printf '%s\n' "$CM_CRDS" > "$w/crds"; printf '%s\n' "$KEYS" > "$w/keys"
t "own IdP needs no Keycloak CRDs" 0 "^OK +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP's client secret has its key" 0 "^OK +IdP client secret" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP's CA has its key" 0 "^OK +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
w=$(world own-idp-nokey); printf '%s\n%s\n' "$CM_CRDS" "$RHBK_CRDS" > "$w/crds"
echo "configmap openshift-config-managed/default-ingress-cert:ca-bundle.crt" > "$w/keys"
t "own IdP's Secret without its key" 1 "^MISSING +IdP client secret +tenant-idp/tenant-idp-client:client-secret" "$w" --step spoke --expect-idp own "${IDP[@]}"
echo "secret tenant-idp/tenant-idp-client:client-secret" > "$w/keys"
t "own IdP's CA without its key" 1 "^MISSING +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP needs both inputs" 2 "^Usage:" "$w" --step spoke --expect-idp own
w=$(world lib-idp)
t "library Keycloak needs no RHBK" 0 "^OK +default StorageClass" "$w" --step spoke --expect-idp library
w=$(world spoke-ok2)
t "bad step" 2 "^Usage:" "$w" --step nope

echo "check-prerequisites tests: $((total-fails)) ok, $fails failed"; exit "$fails"
