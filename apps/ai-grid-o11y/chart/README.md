# Usage logs (ai-grid-o11y)

The usage-logs stack as a chart: the LokiStack, its object storage, the
provisioning hook, the reader and writer identities, the Perses datasource and
dashboard, and the federation of RHOAI's own exporter. The Application reads
`apps/ai-grid-o11y/values-site.yaml` next to the chart for the deployment's
inputs.

## Moving an existing deployment to the chart

With the inputs matching what runs (the storage class the LokiStack has, the
same size, retention and schema date, the claim mode and class) the chart
renders the same object names, namespace and sync waves as the manifests it
replaced, so Argo CD adopts every object in place and recreates nothing; the
sync hook runs once per sync as before. Commit `values-site.yaml` before the
revision that carries the chart, or the render fails and nothing changes.
Changing the namespace or the storage class is not an adoption: a LokiStack
volume class cannot change in place, and a new namespace means a new stack.
The bucket claim and the namespace are never pruned or deleted by the
Application (`Prune=false,Delete=false`): switching to `existingSecret` leaves
the claim, its bucket and credentials in place to retire by hand, and the
namespace, shared with RHOAI's monitoring, stays.

Inputs (`values.yaml` has the defaults):

| Value | Meaning |
|---|---|
| `lokistack.storageClassName` | Required. Block storage class for the LokiStack volumes. |
| `lokistack.size`, `lokistack.retentionDays` | LokiStack size (`1x.demo` default) and retention. |
| `objectStorage.mode` | `obc` (default): a bucket claim on `objectStorage.obc.storageClassName`; the hook reads the claim's endpoint and credentials into the object-storage Secret. `existingSecret`: the deployment provides `objectStorage.existingSecret.name` with Loki's s3 keys (`bucketnames`, `endpoint`, `access_key_id`, `access_key_secret`); no claim, hook or provisioning RBAC is rendered. |
| `objectStorage.obc.caName` / `existingSecret.caName` | ConfigMap with the CA that signs the bucket endpoint's certificate; the service CA bundle covers an in-cluster NooBaa endpoint; empty for a publicly trusted endpoint. |
| `objectStorage.obc.scheme` | `https` (default) or `http` for the endpoint the claim reports; with `https` and a CA named, the hook verifies TLS against that bundle before writing the Secret. |
| `rhoai.monitoringNamespace` | RHOAI's monitoring namespace, where its collector runs; the federation ScrapeConfig and NetworkPolicy target it, independent of the Loki namespace. |
| `job.image` | Image with `oc` and `curl` for the provisioning hook; pin it on a production deployment. |

```yaml
# apps/ai-grid-o11y/values-site.yaml
lokistack:
  storageClassName: <block storage class>
```

Checks: `apps/ai-grid-o11y/tests/chart-render-test.sh` (identities, modes,
inputs) and `apps/ai-grid-o11y/tests/provision-job-test.sh` (the hook's
script against a stub `oc`).
