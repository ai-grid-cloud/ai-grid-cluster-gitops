# Internal model deployments

This app owns the internal `LLMInferenceService` deployment and its
model-facing MaaS resources. Supporting namespaces, NetworkPolicies, and the
Grid `ExternalProvider` are owned by the RHOAI apps.

## Scheduler metrics

The Gateway's serving configuration enables `publishMetrics: true`, so the
model controller publishes each provider's metrics endpoint from the scheduler
Service and its metrics port. The RHOAI prerequisites policy admits
`redhat-ai-grid` to that port.

The model definitions enable the HTTPS listener with
`--metrics-cert-dir=/var/run/kserve/tls`, using the scheduler's existing serving
certificate. The controller image pinned in `apps/rhoai/values.yaml` declares
`appProtocol: https` from this setting and creates per-model ServiceMonitors
that verify the serving certificate. This image pin is temporary until the
platform payload includes that behavior.

The model controller then publishes HTTPS metrics with service-account token
authentication and the `openshift-service-ca.crt` trust bundle in the Grid
namespace. Plaintext token transport remains disabled. New model definitions
also need the metrics TLS argument until the platform's scheduler preset
provides it.

After reconciliation, verify the scheduler metrics Service declares HTTPS,
the provider's `metricsConfig.endpoint` uses HTTPS, and `MetricsAvailable=True`
reports `ScrapeSucceeded`. Prometheus target health alone does not prove the
Grid operator is successfully scraping provider metrics.

## The provider console's catalog

The provider console
([ai-grid-cloud/ai-grid-provider-console](https://github.com/ai-grid-cloud/ai-grid-provider-console))
saves models and subscriptions as commits to a catalog repository,
[ai-grid-cloud/ai-grid-1-catalog](https://github.com/ai-grid-cloud/ai-grid-1-catalog). That URL is the only
value another environment changes: it appears in the two AppProjects and the three ApplicationSets in
`hub/catalog-*`, and in the console's `apps/console/application.yaml`.

The `catalog-*` files in `hub/` deliver it to the clusters Placement `acm-models-catalog` selects (ClusterSet
`global`; narrow it with predicates):

| Catalog path | ApplicationSet | Namespace | Clusters |
|---|---|---|---|
| `catalog/clusters/<cluster>/` | `acm-models-catalog-models` | `ai-grid-internal-models` | Each selected cluster that has a folder: the folder names are where models run |
| `catalog/ingress/` | `acm-models-catalog-ingress` | `models-as-a-service` | Each selected cluster, once the folder exists |
| `catalog/subscriptions/` | `acm-models-catalog-subscriptions` | `models-as-a-service` | Each selected cluster, once the folder exists |

An empty catalog repository generates no Applications, so it shows no errors before the console's first write.

The console's token can push to the catalog, so the catalog's Applications run in two AppProjects that admit only
that repository and only the kinds the console writes:

- `acm-models-catalog-models`: LLMInferenceService, NetworkPolicy, the model's HTTPRoute on the models Gateway
  (`apps/rhoai/grid-models`), and the cluster-scoped InferenceProvider for a combined spoke's own consumer.
- `acm-models-catalog-maas`: ExternalModel, MaaSModelRef, MaaSSubscription and MaaSAuthPolicy, and the cluster-scoped
  InferenceProviders that tell the ingress consumer which site serves each model.

InferenceProvider is the one cluster-scoped kind. The models project needs it only for the combined spoke's local
provider (`grid-<id>-local`, backend `local-models`); the MaaS project for the per-site ones (`grid-<id>-at-<cluster>`).
ValidatingAdmissionPolicies on every spoke (`apps/rhoai/catalog-admission`), matched on Argo CD's own identity (not on
a value in the object), hold the HTTPRoutes and LLMInferenceServices it writes in `ai-grid-internal-models`, and every InferenceProvider it writes, to the shape the
backend writes, with no exemption: the sample models carry the `ai-grid/model` label and an `<id>-grid` route too. A model attaches only to `openshift-ai-inference` with the route KServe builds; a route attaches only to `ai-grid-models` and matches only its own
model id to that model's InferencePool; a provider serves only its own model id, on `local-models` or `peer-<cluster>`,
at the matching site, with the placeholder endpoint and no health check, auth, weights or other routing fields.

A catalog file that collides with an object another Application manages, such as a sample model, stops that
cluster's catalog sync until it's fixed (`FailOnSharedResource`).

Deletion differs by design. Deleting the models ApplicationSet, or a cluster's folder, leaves its models running
(`preserveResourcesOnDeletion`). Deleting an ingress or subscriptions Application deletes its MaaS objects with
it (the resources finalizer), so no access outlives its Application. A teardown can therefore leave a model running
with no MaaS entry: delete its LLMInferenceService by hand.

`apps/ai-grid-policies` reports the catalog's state back to the hub, where the console reads it:

- `ai-grid-models-status`: each LLMInferenceService is Ready.
- `ai-grid-catalog-status`: each MaaSModelRef and ExternalModel is Ready, and each MaaSSubscription and
  MaaSAuthPolicy is Active.

The model controller publishes InferenceProviders automatically. The gateway
backend entries in the RHOAI values files still need to match the providers
that each gateway serves. A catalog model can therefore report Ready before
its gateway backend is configured; model readiness alone does not prove that
requests through MaaS and the Grid gateway can reach it.

Keep anything privileged out of the catalog repository: whoever holds the console's token can write it.
