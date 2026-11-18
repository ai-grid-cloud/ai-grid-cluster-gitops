#!/usr/bin/env bash
# Label two worker Nodes submariner.io/gateway=true so the cluster runs
# Submariner's two gateways (apps/acm/submariner asks for two on every managed
# cluster, the hub included). The add-on has no cloud credentials to label them
# itself.
#
# Usage: scripts/label-gateway-nodes.sh [--context <context>]
#
# Does nothing when two or more Nodes already carry submariner.io/gateway=true.
# Otherwise labels only as many as are missing, choosing Ready, schedulable
# Nodes with the worker role and no control-plane or master role: Nodes without
# a GPU first (no nvidia.com/gpu capacity and no nvidia.com/gpu.present=true),
# then GPU Nodes, each group by name. It never removes or overwrites a label: a
# Node whose submariner.io/gateway is set to anything else is left alone.
# With too few such workers (a compact cluster or single-node OpenShift) it
# labels what it can and prints the command to label the rest by hand.
set -Eeuo pipefail

context_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      [ "$#" -ge 2 ] || { echo "error: --context requires a value" >&2; exit 2; }
      context_args=(--context "$2")
      shift 2
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

label=submariner.io/gateway
want=2

nodes_json="$(kubectl ${context_args[@]+"${context_args[@]}"} get nodes -o json)"

# One line per Node: "<kind> <name>", kind one of labelled, worker, gpu.
rows="$(jq -r --arg label "$label" '
  def roles: [(.metadata.labels // {}) | keys[]
    | select(startswith("node-role.kubernetes.io/"))
    | ltrimstr("node-role.kubernetes.io/")];
  def is_worker: (roles | index("worker")) and
    ((roles | index("control-plane")) or (roles | index("master")) | not);
  def usable: any(.status.conditions[]?; .type == "Ready" and .status == "True")
    and (.spec.unschedulable != true);
  def gpus($field): (((.status[$field] // {})["nvidia.com/gpu"] // "0") | tostring | tonumber? // 0) > 0;
  def gpu: gpus("capacity") or ((.metadata.labels // {})["nvidia.com/gpu.present"] == "true");
  .items | sort_by(.metadata.name)[]
  | (.metadata.labels // {})[$label] as $value
  | if $value == "true" then "labelled \(.metadata.name)"
    elif $value != null or (usable | not) or (is_worker | not) then empty
    elif gpu then "gpu \(.metadata.name)"
    else "worker \(.metadata.name)" end
' <<<"$nodes_json")"

pick() { awk -v kind="$1" '$1 == kind { print $2 }' <<<"$rows"; }

labelled="$(pick labelled)"
have="$(grep -c . <<<"$labelled" || true)"
if [ "$have" -ge "$want" ]; then
  echo "Submariner gateway nodes already labelled: $(paste -sd ' ' - <<<"$labelled")"
  exit 0
fi

need=$((want - have))
candidates="$({ pick worker; pick gpu; } | awk -v n="$need" 'NR <= n')"
for node in $candidates; do
  kubectl ${context_args[@]+"${context_args[@]}"} label node "$node" "$label=true"
  if grep -qxF "$node" <<<"$(pick gpu)"; then
    echo "note: $node has a GPU; no worker without one was left for a Submariner gateway" >&2
  fi
done

got="$(grep -c . <<<"$candidates" || true)"
if [ "$got" -lt "$need" ]; then
  echo "note: $((have + got)) of $want Submariner gateway nodes labelled; no other Ready worker outside the control plane is available." >&2
  echo "note: label $((need - got)) more yourself, for example: kubectl label node <node> $label=true" >&2
fi
