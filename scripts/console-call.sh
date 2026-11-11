#!/usr/bin/env bash
# Make one call to the provider console's API, as the console's own pages do:
# a Connect call through the console's Route, signed in as an OpenShift user.
#
#   console-call.sh --kubeconfig PATH --password-file PATH [--user admin] METHOD [JSON]
#
# METHOD is a Connect path such as ai_grid.v1.Tenants/Create; JSON defaults to {}.
# The user signs in through the htpasswd provider (add-htpasswd-admin.sh); the
# password goes to curl through a netrc file and the token through a header
# file, so neither appears on a command line or in the output.
set -Eeuo pipefail
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
kubeconfig="" password_file="" user=admin
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    *) break ;;
  esac
done
method="${1:-}"; body="${2:-{\}}"
[ -n "$kubeconfig" ] && [ -n "$password_file" ] && [ -n "$method" ] || die "usage: console-call.sh --kubeconfig PATH --password-file PATH METHOD [JSON]"
k() { oc --kubeconfig "$kubeconfig" "$@"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
oauth="$(k get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')"
console="$(k get route -n ai-grid-provider-console -o jsonpath='{.items[0].spec.host}')"
(umask 077; printf 'machine %s login %s password %s\n' "$oauth" "$user" "$(cat "$password_file")" > "$tmp/netrc")
loc="$(curl -sS -o /dev/null -w '%{redirect_url}' --netrc-file "$tmp/netrc" -H 'X-CSRF-Token: 1' \
  "https://$oauth/oauth/authorize?client_id=openshift-challenging-client&response_type=token")"
case "$loc" in *access_token=*) ;; *) die "sign-in as $user failed" ;; esac
(umask 077; printf '%s' "$loc" | sed -E 's/.*access_token=([^&]*).*/Authorization: Bearer \1/' > "$tmp/auth")
curl -sS -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
  --data-binary "$body" -w '\nHTTP %{http_code}\n' "https://$console/$method"
