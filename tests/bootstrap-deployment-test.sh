#!/usr/bin/env bash
# Exercises bootstrap.sh's root_applicationset, the deployment repository fill-in (no cluster).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$HERE/..; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/^root_applicationset() {/,/^}/p' "$ROOT/bootstrap.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "root_applicationset not found in bootstrap.sh" >&2; exit 1; }
fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s\n' "$1"; }
fill() { # profile-file [ENV=VAL ...]: prints the filled root, or fails
  local file=$1; shift
  (cd "$ROOT" && env -i PATH="/usr/bin:/bin" "$@" bash -c "source '$T/fn.sh'; root_applicationset '$file'")
}
for f in bootstrap/applicationset.yaml bootstrap/dedicated-hub/applicationset.yaml; do
  if fill "$f" > "$T/out" && diff -q "$T/out" "$ROOT/$f" >/dev/null; then ok "$f: nothing set leaves the file unchanged"; else bad "$f: nothing set changed the file"; fi
  fill "$f" DEPLOYMENT_REPO_URL=https://example.com/d.git DEPLOYMENT_REVISION=main DEPLOYMENT_PATH=/clusters/demo/ > "$T/out"
  marked=$(grep -c ' # DEPLOYMENT_[A-Z_]*$' "$T/out")
  # Every marked line carries the new value; nothing else changes.
  if [ "$(grep -cE ': (https://example.com/d.git|main|clusters/demo)(/apps/\*\.yaml)? # DEPLOYMENT_' "$T/out")" -eq "$marked" ] && [ "$marked" -gt 0 ]; then
    ok "$f: all $marked marked lines filled"
  else bad "$f: marked lines not all filled"; fi
  if [ "$(diff "$T/out" "$ROOT/$f" | grep -c '^<')" -eq "$marked" ]; then ok "$f: only the marked lines change"; else bad "$f: unmarked lines changed"; fi
  for v in 'a b' 'a"b' 'a\b' 'a#b'; do
    if fill "$f" DEPLOYMENT_REVISION="$v" >/dev/null 2>&1; then bad "$f: accepted revision [$v]"; else ok "$f: refuses revision [$v]"; fi
  done
done
echo "bootstrap-deployment tests: $((total-fails)) ok, $fails failed"; exit "$fails"
