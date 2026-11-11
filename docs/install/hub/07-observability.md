# Observability and usage logs

Two components add AI Grid's dashboards and usage records on the hub. `apps/ai-grid-o11y` scrapes OpenShift AI metrics
into ACM's Thanos, installs the Perses dashboards that the provider console's **Monitoring** page shows, and runs the
LokiStack that stores MaaS usage logs; `apps/ai-grid-usage-logs` installs the Loki operator and tells every ingress or
combined site where to send its usage records. Both depend on [ACM](01-acm.md#red-hat-advanced-cluster-management) observability.

| | |
|---|---|
| Runs on | hub (sites forward usage records to it) |
| Options | On · off |
| Example chose | Off |
| Requires | ACM with its observability ([ACM](01-acm.md)); ODF object storage on the hub; `apps/ai-grid-policies` ([grid](02-grid.md)) |

## Select it

```yaml
- path: apps/ai-grid-o11y/application.yaml
- path: apps/ai-grid-usage-logs/application.yaml
```

The verified install skipped both, so every step on this page is *(Unverified.)*

## Use ours

Before you select them, know their current limits:

- Loki's bucket is an ObjectBucketClaim with StorageClass `openshift-storage.noobaa.io`, so it needs ODF with the
  Multicloud Object Gateway on the hub. The [object-storage](01-acm.md#object-storage) contract doesn't cover Loki, and
  there's no input for another bucket.
- The LokiStack names StorageClass `gp3-csi`, which exists only on AWS.
- The metrics dashboards and the Loki store are one component: you can't take the dashboards without Loki.

Then:

1. Add both components to the `files` list in your root's `kustomization.yaml`. The usage-logs component installs the
   Loki operator that the o11y component's LokiStack needs on a hub without OpenShift AI.

   ```yaml
   - path: apps/ai-grid-o11y/application.yaml
   - path: apps/ai-grid-usage-logs/application.yaml
   ```

2. Select [ACM](01-acm.md#red-hat-advanced-cluster-management) with its observability, an ODF option, and `apps/ai-grid-policies`, which owns namespace
   `ai-grid-policies` where the usage-log credentials live.

They read only `libraryRepoURL` and `libraryRevision` and no file from your deployment repository. `ai-grid-usage-logs`
also renders the `ai-grid-o11y-hub` chart from `opendatahub-io/odh-gitops` `main`. They create:

| What | Where |
|---|---|
| ScrapeConfigs `rhai-metrics` and `ai-grid-dashboard-platform-metrics` | `open-cluster-management-observability`, so ACM collects OpenShift AI and grid metrics from the sites |
| PersesDatasources and PersesDashboards `dashboard-0-cluster-admin`, `dashboard-1-model-admin`, `dashboard-4-maas-usage-logs-admin`, `dashboard-6-ai-grid-routing-admin` | `redhat-ods-monitoring` on the hub, the project the console reads |
| LokiStack `usage-logs` (size `1x.demo`, 30-day retention) and its bucket | `redhat-ods-monitoring` |
| Writer and reader ServiceAccounts, and Jobs that mint one-year tokens for them | `redhat-ods-monitoring`, credentials in `ai-grid-policies` |
| Policy `ai-grid-maas-remote-usage-logs` | Every ingress or combined site: patches `DSCInitialization` with the hub's OTLP endpoint, and delivers Secret `redhat-ods-monitoring/hub-usage-logs-auth` (writer) and `redhat-ai-gateway-infra/usage-logs-loki` (reader) |

The console's Perses URL points at the Cluster Observability Operator's Perses on the hub, which ACM observability
installs when its UI capability is on, as `apps/acm` sets it. Details:
[`apps/ai-grid-usage-logs/README.md`](../../../apps/ai-grid-usage-logs/README.md).

### Verify

```sh
oc get persesdashboards -n redhat-ods-monitoring
oc get lokistack usage-logs -n redhat-ods-monitoring
oc get policy ai-grid-maas-remote-usage-logs -n ai-grid-policies -o jsonpath='{.status.compliant}{"\n"}'
oc --context SITE_CONTEXT get secret usage-logs-loki -n redhat-ai-gateway-infra -o custom-columns=NAME:.metadata.name,TYPE:.type
```

Replace `SITE_CONTEXT` with an ingress or combined site's kubeconfig context.

You should see the four dashboards, the LokiStack Ready, the Policy `Compliant`, and the Secret on the site. The
component README has an end-to-end read check that returns `200`.

## Bring your own

Not supported yet. The console reads `dashboard-*` PersesDashboards from project `redhat-ods-monitoring`
(`apps/console/application.yaml`, `perses.project`), and sites send usage records to the hub Route `usage-logs` in
`redhat-ods-monitoring`. Neither has an input. See [Gaps](../known-gaps.md).

## Skip

You can leave both out; the verified install did. Models, subscriptions and calls work without them. What stops
working:

- The console's **Monitoring** page has no dashboards to show: it reports "Unable to load dashboards" because
  `redhat-ods-monitoring` doesn't exist.
- No site sends usage records, so nobody can see token usage per organization, user or model, in the console's
  dashboard or the Org UI.
- ACM still collects default platform metrics, but not OpenShift AI's or the grid's.

## Upgrade

Both move with the library pin, except the odh-gitops chart, which `apps/ai-grid-usage-logs/application.yaml` reads
from `main`. The usage-log tokens are re-minted on a sync when less than a week remains.

## Known issues

- **Symptom:** The LokiStack never becomes Ready on a hub without ODF, or outside AWS.
  **Cause:** Its bucket comes from NooBaa (`openshift-storage.noobaa.io`) and its StorageClass is `gp3-csi`.
  **Workaround:** Skip both components until the library has a Loki storage input.
- **Symptom:** Policy `ai-grid-maas-remote-usage-logs` is `NonCompliant` for a new site.
  **Cause:** The site's OpenShift AI, which creates the namespaces the Policy writes to, isn't installed yet.
  **Workaround:** None needed. It complies after OpenShift AI is up.
