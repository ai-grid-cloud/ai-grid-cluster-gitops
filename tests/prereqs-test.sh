#!/usr/bin/env bash
# Exercises scripts/prereqs.py against stub tools and a stub oc (no cluster, no
# registry). PATH holds only the stubs and python3, so the host's tools don't count.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/prereqs.py"
PY=$(command -v python3); GIT=$(command -v git)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TOKEN=c3R1Yi11c2VyOkZBS0VfVE9LRU5fZG9fbm90X3ByaW50XzQyNDI0Mg==   # base64 of stub-user:FAKE_TOKEN_do_not_print_424242
PASSWORD=FAKE_TOKEN_do_not_print_424242

# Every stub uses only bash builtins: PATH has nothing else on it.
mkbin() { # dir: a bin dir with every tool stubbed
  local b=$1; mkdir -p "$b"; ln -sf "$PY" "$b/python3"
  # git answers --version itself and passes rev-parse on to the real git.
  printf '#!/bin/bash\n[ "$1" = --version ] && { echo "git version 1.2.3"; exit; }\nexec %s "$@"\n' "$GIT" > "$b/git"
  for t in kubectl jq curl openssl base64 htpasswd clusteradm make; do
    printf '#!/bin/bash\necho "%s 1.2.3"\n' "$t" > "$b/$t"
  done
  printf '#!/bin/bash\necho v5.8.3\n' > "$b/kustomize"
  # The stub oc logs its arguments and answers from files in $STUB_DIR; a
  # missing file is an empty answer. A file "fail-<verb>" makes that call fail.
  cat > "$b/oc" <<'END_STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; args=" $* "
answer() { [ -f "$d/$1" ] && echo "$(<"$d/$1")"; return 0; }
case "$args" in
  *" version --client "*) echo "Client Version: 4.22.17" ;;
  *" whoami --show-server "*) [ -f "$d/fail-whoami" ] && { echo "error: Unauthorized" >&2; exit 1; }; echo https://api.stub:6443 ;;
  *" get clusterversion version "*) answer version ;;
  *" auth can-i "*) answer can-i ;;
  *" get storageclasses."*) answer storageclasses.json ;;
  *" get clusterissuers."*) [ -f "$d/fail-issuers" ] && { echo 'error: the server doesn'"'"'t have a resource type "clusterissuers"' >&2; exit 1; }; answer clusterissuers.json ;;
  *" image info "*)
    [ -f "$d/fail-image" ] && { echo "error: unauthorized: access to the requested resource is not authorized (auth $(<"$d/leak"))" >&2; exit 1; }
    echo "Name: quay.io/rhoai/rhoai-fbc-fragment" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
END_STUB
  for f in "$b"/*; do [ -L "$f" ] || chmod 755 "$f"; done
}

world() { # name: a fresh stub cluster that passes every check
  local w="$T/$1"; rm -rf "$w"; mkdir -p "$w"
  echo "4.22.18" > "$w/version"; echo yes > "$w/can-i"
  echo '{"items":[{"metadata":{"name":"gp3-csi","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}' > "$w/storageclasses.json"
  echo '{"items":[{"metadata":{"name":"le-dns"},"spec":{"acme":{"solvers":[{"dns01":{"route53":{}}}]}}}]}' > "$w/clusterissuers.json"
  echo "$TOKEN" > "$w/leak"
  echo "$w"
}

authfile() { # name, keys...: an auth file with these registries, each holding the fake token
  local f="$T/$1.json"; shift; local sep="" body=""
  for k in "$@"; do body="$body$sep\"$k\":{\"auth\":\"$TOKEN\"}"; sep=,; done
  echo "{\"auths\":{$body}}" > "$f"; echo "$f"
}

mkbin "$T/bin"
fails=0; total=0
t() { # name expect_regex bin world [args...]; also checks rc 0 and no secret in the output
  local name=$1 expect=$2 bin=$3 w=$4; shift 4; local rc out
  total=$((total+1))
  out=$(env -i PATH="$bin" HOME="$T" STUB_DIR="$w" "$PY" "$SCRIPT" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && grep -qE -- "$expect" <<<"$out" && ! grep -qE "$TOKEN|$PASSWORD" <<<"$out"; then
    printf '   ok   %s\n' "$name"
  else
    printf '   FAIL %s (rc=%s; output:)\n%s\n' "$name" "$rc" "$out"; fails=$((fails+1))
  fi
}

w=$(world all-ok); A=$(authfile both quay.io/rhoai registry.stage.redhat.io)
TOK="$T/token"; printf 'x' > "$TOK"; chmod 600 "$TOK"
D="$T/deployment"; mkdir -p "$D/root"
printf '        libraryRevision: %s\n' "$("$GIT" -C "$HERE/.." rev-parse HEAD)" > "$D/root/kustomization.yaml"
ALL=(--deployment "$D" --hub-context hub --site-context site --quay-auth-file "$A" --catalog-token-file "$TOK")
t "all ok: no problem lines" '^[0-9]+ ok$' "$T/bin" "$w" "${ALL[@]}"
t "all ok: kustomize version" '^ok +kustomize +5\.8\.3' "$T/bin" "$w" "${ALL[@]}"
t "all ok: site ClusterIssuer with DNS-01" '^ok +ClusterIssuer +le-dns \(DNS-01\)' "$T/bin" "$w" "${ALL[@]}"
t "all ok: catalog pulls" '^ok +pull the pinned catalog +quay.io/rhoai/rhoai-fbc-fragment' "$T/bin" "$w" "${ALL[@]}"
if grep -qE "$TOKEN|$PASSWORD" "$w/argv.log"; then echo "   FAIL a secret reached oc's argv"; fails=$((fails+1)); else echo "   ok   no secret on oc's argv"; fi
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale' "$w/argv.log"; then
  echo "   FAIL oc got a write verb"; fails=$((fails+1)); else echo "   ok   oc calls are read-only"; fi
total=$((total+2))

t "library at the pin" '^ok +library at your pin' "$T/bin" "$w" "${ALL[@]}"
mkdir -p "$T/other/root"; echo "  libraryRevision: 0123456789abcdef0123456789abcdef01234567" > "$T/other/root/kustomization.yaml"
t "library not at the pin" '^FAIL +library at your pin +.* not 0123456789ab: git -C ' "$T/bin" "$w" --deployment "$T/other"

mkbin "$T/nojq"; rm "$T/nojq/jq"
t "missing tool" '^MISSING +jq ' "$T/nojq" "$w"
t "missing tool: summary and note" 'Nothing was changed' "$T/nojq" "$w"
mkbin "$T/oldk"; printf '#!/bin/bash\necho "{Version:kustomize/v4.5.7 GitCommit:abc}"\n' > "$T/oldk/kustomize"; chmod 755 "$T/oldk/kustomize"
t "kustomize v4 is OLD" '^OLD +kustomize +4\.5\.7; version 5 or later needed' "$T/oldk" "$w"

t "nothing set: registry skipped" '^skipped +registry logins +set QUAY_AUTH_FILE' "$T/bin" "$w"
t "nothing set: hub skipped" '^skipped +hub checks +set HUB_CONTEXT' "$T/bin" "$w"
t "nothing set: site skipped" '^skipped +site checks +set SITE_CONTEXT' "$T/bin" "$w"
t "nothing set: token skipped" '^skipped +catalog token file' "$T/bin" "$w"

t "quay.io/rhoai and stage" '^ok +registry.stage.redhat.io login' "$T/bin" "$w" --quay-auth-file "$A"
G=$(authfile generic quay.io registry.stage.redhat.io)
t "general quay.io login: ok with the note" '^ok +quay.io/rhoai login +general quay.io entry: page 3 needs RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1' "$T/bin" "$w" --quay-auth-file "$G"
N=$(authfile nostage quay.io/rhoai)
t "no stage login" '^MISSING +registry.stage.redhat.io login' "$T/bin" "$w" --quay-auth-file "$N"
O=$(authfile other docker.io)
t "no quay login" '^MISSING +quay.io/rhoai login' "$T/bin" "$w" --quay-auth-file "$O"
t "auth file not found" '^MISSING +auth file' "$T/bin" "$w" --quay-auth-file "$T/nope.json"
touch "$w/fail-image"
t "registry refuses: FAIL, token scrubbed" '^FAIL +pull the pinned catalog +.*unauthorized' "$T/bin" "$w" --quay-auth-file "$A"
rm "$w/fail-image"

w=$(world old); echo "4.20.5" > "$w/version"; echo no > "$w/can-i"
echo '{"items":[{"metadata":{"name":"gp2"}}]}' > "$w/storageclasses.json"
t "OpenShift 4.20 is OLD" '^OLD +OpenShift 4.21 or later +4.20.5' "$T/bin" "$w" --hub-context hub
t "not cluster-admin" '^MISSING +cluster-admin' "$T/bin" "$w" --hub-context hub
t "no default StorageClass" '^MISSING +default StorageClass' "$T/bin" "$w" --hub-context hub
echo '{"items":[{"metadata":{"name":"self-signed"},"spec":{"selfSigned":{}}}]}' > "$w/clusterissuers.json"
t "ClusterIssuer without DNS-01" '^MISSING +ClusterIssuer +self-signed \(no DNS-01\)' "$T/bin" "$w" --site-context site
touch "$w/fail-issuers"
t "no cert-manager" '^MISSING +ClusterIssuer +error: the server' "$T/bin" "$w" --site-context site
touch "$w/fail-whoami"
t "unreachable cluster" '^FAIL +reachable +context hub: error: Unauthorized' "$T/bin" "$w" --hub-context hub
t "unreachable cluster skips the rest" '^skipped +cluster-admin +cluster not reachable' "$T/bin" "$w" --hub-context hub

printf 'x' > "$T/loose"; chmod 644 "$T/loose"; : > "$T/empty"; chmod 600 "$T/empty"
t "token file too open" '^FAIL +catalog token file +.* mode 644' "$T/bin" "$w" --catalog-token-file "$T/loose"
t "token file empty" '^FAIL +catalog token file +.* empty' "$T/bin" "$w" --catalog-token-file "$T/empty"
t "token file missing" '^MISSING +catalog token file' "$T/bin" "$w" --catalog-token-file "$T/none"
out=$(env -i PATH="$T/bin" HOME="$T" STUB_DIR="$w" CATALOG_TOKEN_FILE="$TOK" "$PY" "$SCRIPT" 2>&1) || true
total=$((total+1)); if grep -qE '^ok +catalog token file' <<<"$out"; then echo "   ok   env vars work like options"; else echo "   FAIL env vars work like options"; fails=$((fails+1)); fi

echo "prereqs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
