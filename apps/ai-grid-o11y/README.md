# AI Grid hub observability

Hub metrics and usage-log resources, with the Loki operator dependency for a dedicated hub.

The ai-grid-o11y Application delivers the resources in `manifests/`, including
`LokiStack/usage-logs`. The Loki operator must run on the same cluster as that
stack; installing it on a spoke does not supply the hub's API.

## Dedicated hub

The dedicated-hub root adds `loki-operator/` as an additional source of the same
Application. The source inherits the observability Application's repository and
revision, including when the deployment uses a fork. It installs only Loki's
OLM OperatorGroup and Subscription; it does not select the hub as a Grid site
or install RHOAI workloads.

The OperatorGroup is in wave -3 and the Subscription in wave -2, before the
observability manifests (wave -1 and later). The repository's Subscription
health check waits for an installed CSV and AtLatestKnown before the next wave.
`SkipDryRunOnMissingResource=true` allows the initial plan while the operator
has not established the LokiStack API yet.

Operator settings match RHOAI's pinned `rhai-on-openshift-chart` 3.6.0-dev.13.1:
`loki-operator`, `stable-6.5`, `redhat-operators` in `openshift-marketplace`,
automatic install approval, and no separate CSV pin. Keep the channel aligned
when changing the RHOAI chart's Loki version policy.

The operator uses OpenShift's existing `openshift-operators-redhat` namespace;
this Application does not create or take ownership of that platform namespace.
The all-namespaces OperatorGroup uses the RHOAI chart's standard name and is
retained on prune/deletion because other operators can share it. If the hub
already has a Loki Subscription or OperatorGroup with different names, reconcile
that existing installation into the deployment configuration before enabling
this source; do not create a second group or subscription in the same namespace.

Combined hubs keep the original single source. Their RHOAI chart continues to
own the Loki dependency. Switching profiles requires deliberate ownership
handoff; the source change is not an operator uninstall procedure.

## Validation

The local test renders both roots' actual Go/Sprig template patches using Helm:

```bash
python3 apps/ai-grid-o11y/tests/dedicated-hub-test.py
```

To compare the version policy with the exact RHOAI artifact, pull the chart
version from `apps/rhoai/hub/01-applicationset.yaml`, then run:

```bash
python3 apps/ai-grid-o11y/tests/dedicated-hub-test.py \
  --rhoai-chart-values /path/to/rhai-on-openshift-chart/values.yaml
```

After publication, an authorized operator reapplies the dedicated-hub root
as described in the hub onboarding guide, then verifies the Loki Subscription
and CSV, established LokiStack CRD, usage-logs readiness, object storage and
usage-log ingestion/querying. The render tests do not establish runtime readiness.
