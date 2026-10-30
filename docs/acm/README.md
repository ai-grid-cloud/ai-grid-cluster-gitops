# Getting started

An AI Grid on ACM takes three steps: a hub, then clusters, then models.

## Dependencies

| Dependency | Where | Who provides it |
|---|---|---|
| OpenShift cluster with ACM and cert-manager | hub | you |
| Fork of this repository, readable by the hub's Argo CD | hub | you |
| Pull credentials for quay.io/rhoai, and registry.stage.redhat.io for pre-release model images | hub, once | you, as environment variables to the bootstrap script |
| Catalog pull Secret, global pull Secret entries, image mirror | every cluster | policy, from the hub |
| Default StorageClass: 20Gi metrics and 10Gi traces for RHOAI monitoring, 20Gi for a MaaS database replica on an ingress or combined site | every site | you |
| Submariner gateway nodes, two per cluster, and its cloud prerequisites | every site | you, the add-on comes from the hub |
| A default router the other sites can reach, for the provider gateway on 443 | every site | you |
| Capacity for the models: the samples run three replicas of 1 CPU and 10Gi each, a GPU model needs GPU nodes and the NVIDIA operator | every site | you |
| Grid CA, grid ID, site identities, grid CRDs and operator, RHOAI | every site | the hub, through policies and Argo |

## 1. Hub

Install Argo CD and ACM, point the fork at itself, run the bootstrap script.
Argo installs everything under apps, including the grid bootstrap that mints
the grid ID and delivers each member's identity.

Guide: [hub onboarding](hub-onboarding/README.md).

## 2. Cluster

Import the cluster into ACM, then label it:

```sh
oc label managedcluster <name> ai-grid/enabled=true ai-grid/role=combined
```

The first label joins the grid. The role (ingress, inference, or combined)
decides what gets installed. No cluster-specific file goes into Git. The grid
operator derives all gateway routing from the models each site publishes.

Guide: [cluster onboarding](cluster-onboarding/README.md).

## 3. Models

Label a project namespace and deploy a model into it:

```sh
oc label namespace <project> grid.opendatahub.io/allowed=true
```

The model controller publishes the model to the grid. No per-model entry in Git.

Guide: [AI project onboarding](ai-project-onboarding/README.md).

## Verification

- Hub: every Application Synced and Healthy, Policies Compliant.
- Site: every InferenceProvider Available.
- End to end: the [MaaS smoke test](../maas-oidc-smoke/README.md) gets a
  completion as a tenant user.

## Layout

| Concern | Path |
|---|---|
| Hub bootstrap and grid identity | apps/grid-bootstrap |
| Which clusters are sites, in what role | apps/ai-grid-spokes |
| RHOAI, grid operator and gateways | apps/rhoai |
| Namespaces, policies, pull secrets | apps/rhoai-prerequisites |
| Models and MaaS objects | apps/acm-models |
| MaaS database | apps/maas-db |
| Submariner | apps/acm/submariner |
