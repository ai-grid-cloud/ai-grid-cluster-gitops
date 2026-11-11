#!/usr/bin/env bash
# Add an htpasswd admin sign-in next to a cluster's existing identity providers.
#
# When a cluster's only sign-in is an external identity provider (such as a
# platform Keycloak) and that provider is ever lost, everyone is locked out, so
# add this sign-in and confirm it works before removing anything from a cluster.
# The existing providers are kept; the new one uses mappingMethod "add", so the
# same user name signs in through either provider.
#
# The password is generated into PASSWORD_FILE (mode 600) when that file doesn't
# exist, and is never printed.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: add-htpasswd-admin.sh --kubeconfig PATH --password-file PATH [--user NAME] [--idp NAME]

  --kubeconfig     kubeconfig of a cluster-admin session on the target cluster
  --password-file  where the admin's password is kept; generated if missing
  --user           user name; defaults to admin
  --idp            identity provider name; defaults to htpasswd
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kubeconfig="" password_file="" user=admin idp=htpasswd
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --idp) idp="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[ -n "$kubeconfig" ] && [ -n "$password_file" ] || { usage >&2; die "--kubeconfig and --password-file are required"; }
for c in oc htpasswd openssl python3 curl; do command -v "$c" >/dev/null || die "required command not found: $c"; done

k() { oc --kubeconfig "$kubeconfig" "$@"; }
secret="${idp}-htpasswd"

if [ ! -s "$password_file" ]; then
  (umask 077; openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-32 > "$password_file")
  echo "Generated a password in $password_file."
fi
chmod 600 "$password_file"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# -i reads the password from stdin, so it never appears in the process list.
htpasswd -niB "$user" < "$password_file" > "$tmp/htpasswd"
k create secret generic "$secret" -n openshift-config --from-file=htpasswd="$tmp/htpasswd" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
echo "Created or updated openshift-config/$secret."

# Append the provider only if no provider has this name; keep every existing one.
k get oauth cluster -o json > "$tmp/oauth.json"
if python3 - "$tmp/oauth.json" "$idp" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
names = [p["name"] for p in o.get("spec", {}).get("identityProviders", []) or []]
sys.exit(0 if sys.argv[2] in names else 1)
PY
then
  echo "Identity provider $idp already present."
else
  if python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); sys.exit(0 if o.get("spec",{}).get("identityProviders") else 1)' "$tmp/oauth.json"; then
    op='[{"op":"add","path":"/spec/identityProviders/-","value":{"name":"'"$idp"'","type":"HTPasswd","mappingMethod":"add","htpasswd":{"fileData":{"name":"'"$secret"'"}}}}]'
  else
    op='[{"op":"add","path":"/spec/identityProviders","value":[{"name":"'"$idp"'","type":"HTPasswd","mappingMethod":"add","htpasswd":{"fileData":{"name":"'"$secret"'"}}}]}]'
  fi
  k patch oauth cluster --type=json -p "$op" >/dev/null
  echo "Added identity provider $idp."
fi

k adm policy add-cluster-role-to-user cluster-admin "$user" >/dev/null
echo "Granted cluster-admin to $user."

# Wait for the OAuth server to roll out with the new provider, then sign in
# with it. The password goes to curl through a netrc file and the token into a
# throwaway kubeconfig, so neither appears on a command line.
oauth_host="$(k get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')"
[ -n "$oauth_host" ] || die "no oauth-openshift route"
(umask 077; printf 'machine %s login %s password %s\n' "$oauth_host" "$user" "$(cat "$password_file")" > "$tmp/netrc")
k config view --minify --raw > "$tmp/verify"
for i in $(seq 1 60); do
  location="$(curl -sS -o /dev/null -w '%{redirect_url}' --netrc-file "$tmp/netrc" -H 'X-CSRF-Token: 1' \
    "https://$oauth_host/oauth/authorize?client_id=openshift-challenging-client&response_type=token" || true)"
  case "$location" in
    *access_token=*)
      python3 - "$tmp/verify" "$location" <<'PY'
import sys, urllib.parse, yaml
path, loc = sys.argv[1], sys.argv[2]
token = urllib.parse.parse_qs(urllib.parse.urlparse(loc).fragment)["access_token"][0]
cfg = yaml.safe_load(open(path))
ctx = next(c for c in cfg["contexts"] if c["name"] == cfg["current-context"])["context"]
cfg["users"] = [{"name": ctx["user"], "user": {"token": token}}]
yaml.safe_dump(cfg, open(path, "w"))
PY
      who="$(oc --kubeconfig "$tmp/verify" whoami)"
      [ "$who" = "$user" ] || die "signed in as $who, expected $user"
      echo "Verified: $user signs in through $idp."
      exit 0 ;;
  esac
  sleep 10
done
die "could not sign in as $user through $idp within 10 minutes"
