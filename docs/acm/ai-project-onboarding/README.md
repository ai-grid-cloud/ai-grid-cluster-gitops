# AI project onboarding

How an AI project namespace and its models join the grid on a cluster that already runs RHOAI. A cluster gets RHOAI by its `ai-grid/enabled=true` label: see [cluster onboarding](../cluster-onboarding/README.md).

## Add a project namespace

Create the namespace and opt it in with one label:

```bash
oc create namespace <project>
oc label namespace <project> grid.opendatahub.io/allowed=true
```

The label is the only switch. On every cluster in the grid it gives the namespace:

- route admission on the inference gateway (`openshift-ai-inference`), whose listeners select namespaces by this label;
- the NetworkPolicies from the `rhoai-prerequisites` policy, which isolate the model pods and admit only the scheduler, the router, the Grid namespace and RHOAI's metrics collector;
- InferenceProvider publication: the model controller publishes each LLMInferenceService in a labelled namespace whose Gateway carries the Grid serving annotation.

`ai-grid-internal-models` is created with the label, and is where the catalog deploys models.

## Deploy a model

Use the provider console, which writes the model to the catalog repository, or commit an `LLMInferenceService` to a labelled namespace. See [apps/acm-models](../../../apps/acm-models/README.md) for the catalog, its AppProjects and the sample models.

A model definition needs:

- its router attached to the `openshift-ai-inference` Gateway in `openshift-ingress`;
- the scheduler's metrics TLS argument, `--metrics-cert-dir=/var/run/kserve/tls`, until the platform's scheduler preset provides it.

Still manual per model, until the gateways generate their routing from the published providers:

- a backend entry in `apps/rhoai/values-<cluster>.yaml` for the consumer gateway;
- a backend entry in `apps/rhoai/provider-gateway-<cluster>.yaml` for the provider gateway.

## Verify

- `oc -n <project> get networkpolicy` includes `grid-gateway-backend`, `llminference-engine-serving`, `llminference-scheduler-serving` and `rhoai-collector-metrics`, and the `rhoai-prerequisites` policy is Compliant.
- The model's HTTPRoute reports Accepted on `openshift-ai-inference`.
- `oc get inferenceproviders` shows the model's provider `Available`, with `MetricsAvailable=True`.
