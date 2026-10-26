# Sharded ACM model deployments

This app deploys two additional models without changing the existing
`apps/acm-models` application:

- `SmolLM2-135M-Instruct` runs on exactly one selected cluster.
- `SmolLM2-360M-Instruct` runs on every other registered cluster.

GitOps only syncs the ACM/OCM resources in `hub/`. OCM `Policy` resources
propagate the model catalog, authentication, and workload resources to the
managed clusters. There are no Argo CD `ApplicationSet` resources in this app.

The existing `apps/acm-models` application continues to own `facebook-opt-125m`
and the shared model namespace, provider, and network policy resources.

## UI scheduling contract

A UI that schedules model deployments needs to create three OCM resources:

1. A `Placement` that selects the target cluster.
2. A `Policy` that contains the model resources to deploy.
3. A `PlacementBinding` that connects the Policy to the Placement.

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: example-model-anchor
  namespace: acm-models-sharding
spec:
  clusterSets:
    - global
  numberOfClusters: 1
---
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: example-model
  namespace: acm-models-sharding
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: example-model
        spec:
          remediationAction: enforce
          severity: low
          pruneObjectBehavior: DeleteAll
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: inference.opendatahub.io/v1alpha1
                kind: ExternalModel
                metadata:
                  name: example-model
                  namespace: models-as-a-service
                spec:
                  externalProviderRefs:
                    - apiFormat: openai-chat
                      path: /v1/chat/completions
                      ref:
                        name: grid-provider
                      targetModel: example/model
                      weight: 1
            - complianceType: musthave
              objectDefinition:
                apiVersion: serving.kserve.io/v1alpha2
                kind: LLMInferenceService
                metadata:
                  name: example-model
                  namespace: ai-grid-internal-models
                spec:
                  replicas: 1
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: example-model
  namespace: acm-models-sharding
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: example-model-anchor
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: example-model
```

This app uses the same contract, with one common Policy for resources that
must exist on every cluster and two workload Policies for the sharded models.
OCM reconciles asynchronously, so the complement Placement can briefly select
every cluster before the anchor Policy propagates its ClusterClaim.

## Dependencies

This app relies on the existing `apps/acm-models` application for:

- the `ai-grid-internal-models` and `models-as-a-service` namespaces;
- the `grid-provider` ExternalProvider;
- the Grid network policies.

## Validation

After syncing this app, verify the OCM resources and decisions:

```sh
kubectl -n acm-models-sharding get placements
kubectl -n acm-models-sharding get placementdecisions
kubectl -n acm-models-sharding get policies
kubectl -n acm-models-sharding get placementbindings
```
