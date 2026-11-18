#!/usr/bin/env bash
# Exercises scripts/label-gateway-nodes.sh against a stub kubectl (no cluster).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
cat > "$T/bin/kubectl" <<'END_STUB'
#!/usr/bin/env bash
# "get nodes -o json" prints $STUB_NODES; "label node N L" appends "N L" to $STUB_LOG. Any --context is logged too.
args=("$@"); ctx=""
if [ "${args[0]}" = --context ]; then ctx="${args[1]}"; args=("${args[@]:2}"); fi
case "${args[0]} ${args[1]}" in
  "get nodes") cat "$STUB_NODES" ;;
  "label node") echo "${args[2]} ${args[3]}${ctx:+ context=$ctx}" >> "$STUB_LOG" ;;
  *) echo "stub kubectl: unexpected: $*" >&2; exit 1 ;;
esac
END_STUB
chmod 700 "$T/bin/kubectl"
# node NAME ROLES(comma) [gateway=VALUE] [gpu] [notready] [cordoned]
node() {
  local name=$1 roles=$2; shift 2; local labels="" gpu=0 ready=True unsched=false
  for r in ${roles//,/ }; do labels+="\"node-role.kubernetes.io/$r\":\"\","; done
  for o in "$@"; do case $o in
    gateway=*) labels+="\"submariner.io/gateway\":\"${o#gateway=}\"," ;;
    gpu) gpu=1; labels+='"nvidia.com/gpu.present":"true",' ;;
    gpucap) gpu=1 ;;
    notready) ready=False ;;
    cordoned) unsched=true ;;
  esac; done
  printf '{"metadata":{"name":"%s","labels":{%s}},"spec":{"unschedulable":%s},"status":{"capacity":{"nvidia.com/gpu":"%s"},"conditions":[{"type":"Ready","status":"%s"}]}}' \
    "$name" "${labels%,}" "$unsched" "$gpu" "$ready"
}
fails=0; total=0
# t NAME EXPECTED_LABELS ARGS -- NODE-SPECS (one per argument, ';'-separated fields)
t() {
  local name=$1 want=$2 args=$3; shift 3; local items="" got rc
  for spec in "$@"; do IFS=';' read -r -a f <<<"$spec"; items+="$(node "${f[@]}"),"; done
  printf '{"items":[%s]}' "${items%,}" > "$T/nodes.json"; : > "$T/log"
  total=$((total+1))
  # shellcheck disable=SC2086 # $args is split on purpose
  (env -i PATH="$T/bin:/usr/bin:/bin:$(dirname "$(command -v jq)")" STUB_NODES="$T/nodes.json" STUB_LOG="$T/log" \
    bash "$HERE/../scripts/label-gateway-nodes.sh" $args > "$T/out" 2>&1) && rc=0 || rc=$?
  got=$(paste -sd '|' - < "$T/log")
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then printf '   ok   %-40s labelled: %s\n' "$name" "${got:-none}"
  else printf '   FAIL %-40s rc=%s labelled: %s wanted: %s\n' "$name" "$rc" "${got:-none}" "${want:-none}"; sed 's/^/        /' "$T/out"; fails=$((fails+1)); fi
}
L=submariner.io/gateway=true
t picks-non-gpu-workers-first "w-b $L|w-c $L" "" \
  "gpu-a;worker;gpu" "w-c;worker" "w-b;worker" "m-0;control-plane,master"
t gpu-capacity-counts-as-gpu "w-a $L|g-b $L" "" \
  "g-b;worker;gpucap" "w-a;worker"
t uses-gpu-only-when-needed "w-a $L|gpu-z $L" "" \
  "gpu-z;worker;gpu" "w-a;worker"
t no-op-when-two-labelled "" "" \
  "w-a;worker;gateway=true" "w-b;worker;gateway=true" "w-c;worker"
t no-op-when-three-labelled "" "" \
  "w-a;worker;gateway=true" "w-b;worker;gateway=true" "w-c;worker;gateway=true"
t tops-up-one-labelled "w-c $L" "" \
  "w-a;worker;gateway=true" "w-b;worker;gpu" "w-c;worker"
t never-touches-other-gateway-value "w-b $L|w-c $L" "" \
  "w-a;worker;gateway=false" "w-b;worker" "w-c;worker"
t skips-notready-cordoned-and-control-plane "w-d $L" "" \
  "w-a;worker;notready" "w-b;worker;cordoned" "cp-c;control-plane,master,worker" "w-d;worker"
t compact-cluster-labels-nothing "" "" \
  "m-0;control-plane,master,worker" "m-1;control-plane,master,worker" "m-2;control-plane,master,worker"
t infra-worker-is-eligible "i-a $L|w-b $L" "" \
  "i-a;infra,worker" "w-b;worker"
t passes-context "w-a $L context=spoke|w-b $L context=spoke" "--context spoke" \
  "w-a;worker" "w-b;worker"
echo "label-gateway-nodes tests: $((total-fails)) ok, $fails failed"; exit "$fails"
