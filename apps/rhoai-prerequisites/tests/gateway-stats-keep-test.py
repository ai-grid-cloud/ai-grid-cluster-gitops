#!/usr/bin/env python3
"""The gateway stats monitor keeps the Envoy families a gateway view needs and drops the rest."""
import os, re, sys
import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
policy = os.path.join(ROOT, "apps/rhoai-prerequisites/hub/15-rhoai-source-metrics-policy.yaml")
NEEDED = ["envoy_http_downstream_rq_total", "envoy_http_downstream_rq_time_bucket", "envoy_http_downstream_cx_active",
          "envoy_http_downstream_rq_active", "envoy_listener_downstream_cx_overflow", "envoy_cluster_upstream_rq_time_bucket",
          "envoy_cluster_upstream_cx_connect_fail", "envoy_cluster_upstream_rq_pending_active", "envoy_server_memory_allocated",
          "envoy_server_live", "envoy_http_ext_proc_streams_failed", "envoy_http_ext_authz_denied",
          "envoy_cluster_kuadrant_ratelimit_service_upstream_rq_total", "envoy_wasm_kuadrant_wasm_shim_vm_reload_failure",
          "istio_requests_total", "istio_request_duration_milliseconds_bucket"]
UNUSED = ["envoy_cluster_assignment_stale", "envoy_http_downstream_rq_http1_total", "envoy_runtime_load_success",
          "envoy_cluster_manager_cds_update_success"]


def find_monitor(node):
    if isinstance(node, dict):
        if node.get("kind") == "PodMonitor" and node.get("metadata", {}).get("name") == "ai-grid-gateway-collector-stats":
            return node
        node = list(node.values())
    if isinstance(node, list):
        for item in node:
            found = find_monitor(item)
            if found:
                return found
    return None


monitor = next(m for m in (find_monitor(d) for d in yaml.safe_load_all(open(policy))) if m)
keep = [r for r in monitor["spec"]["podMetricsEndpoints"][0]["metricRelabelings"]
        if r["action"] == "keep" and r["sourceLabels"] == ["__name__"]]
assert len(keep) == 1, "expected one __name__ keep rule"
kept = re.compile("^(?:%s)$" % keep[0]["regex"])  # Prometheus anchors relabel regexes
failures = ["needed family dropped: " + n for n in NEEDED if not kept.match(n)]
failures += ["unused family kept: " + n for n in UNUSED if kept.match(n)]
for f in failures:
    print("FAIL", f)
print("gateway stats keep-list: %d needed, %d unused, %d failures" % (len(NEEDED), len(UNUSED), len(failures)))
sys.exit(1 if failures else 0)
