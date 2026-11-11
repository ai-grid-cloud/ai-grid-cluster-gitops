# Spokes

A spoke, or site, is an OpenShift cluster the hub makes part of the grid. You don't install anything on a site
yourself: you prepare the cluster, import it into ACM, label it with its role, and the hub installs the rest
([prepare each site](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/05-prepare-site.md), [join each site to the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md)). So a site has almost no
component choices: the hub installs the odh-gitops `rhai-on-openshift-chart` Helm chart in the site's role, with the
library's values, the role's values and your values for that site.

## What each site brings

| Requirement | Details |
|---|---|
| OpenShift 4.21 or later | `check-prerequisites.sh --step spoke` checks it ([prepare each site](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/05-prepare-site.md#4-check-the-sites-infrastructure)) |
| A default StorageClass | OpenShift AI monitoring claims 20 GiB and 10 GiB; the MaaS database replica on an ingress or combined site claims 20 GiB |
| A load balancer | Your cloud's, or MetalLB on bare metal ([site networking](networking.md#load-balancers)) |
| Two Submariner gateway nodes | Worker-only nodes are labelled for you; label them by hand on compact clusters and single-node OpenShift ([site networking](networking.md#submariner-gateways)) |
| DNS with no `NXDOMAIN` on `AAAA` | Every router name answers `AAAA` queries with an address or an empty answer ([site networking](networking.md#dns)) |
| GPUs, for GPU models | Inference and combined sites only; CPU-only sites serve CPU models ([GPU operator and NFD](openshift-ai.md#nvidia-gpu-operator-and-node-feature-discovery)) |
| `cluster-admin`, and a break-glass admin | [Cluster sign-in and admins](../hub/00-platform-services.md#cluster-sign-in-and-admins) |

## What you choose per site

| Choice | Options | Where you set it |
|---|---|---|
| Role | `ingress`: tenants enter here, no models. `inference`: models, reached only by ingress sites. `combined`: both. | The `ai-grid/role` label ([join each site to the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md#2-label-the-site)) |
| MaaS hostname prefix (ingress and combined) | Any DNS label; `maas` by default, and with the library's Keycloak | `values/clusters/SITE/rhoai.yaml` ([join each site to the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md#1-add-the-sites-values)) |
| MaaS gateway certificate (ingress and combined) | A DNS-01 ClusterIssuer on the site, or your own certificate | Your own app and the same values file ([MaaS gateway certificate](maas-certificate.md)) |
| Location | Any label value, such as `us-east` | The `location` label |
| GPU operator configuration (inference and combined, with GPUs) | Your `NodeFeatureDiscovery` and `ClusterPolicy` specs | `values/clusters/SITE/rhoai.yaml` ([GPU operator and NFD](openshift-ai.md#nvidia-gpu-operator-and-node-feature-discovery)) |
| MetalLB address range (bare metal) | An IPv4 range | The `ai-grid/metallb-pool` label ([site networking](networking.md#use-ours)) |

The smallest grid is one combined site. A typical grid is one ingress site plus inference sites.

## What the hub installs there

| What | Roles | From |
|---|---|---|
| OpenShift AI, in the role's profile, with its operators: cert-manager, the NVIDIA GPU Operator and NFD (inference and combined) | all | [OpenShift AI on each site](openshift-ai.md) |
| MaaS, the MaaS gateway, the Org UI and the grid consumer gateway; the tenant settings | ingress, combined | [OpenShift AI on each site](openshift-ai.md#openshift-ai-with-maas) |
| The grid operator and provider gateway; the models from the catalog | inference, combined | [OpenShift AI on each site](openshift-ai.md#openshift-ai-with-maas), [model delivery](../hub/05-console-and-model-delivery.md#model-delivery) |
| Grid membership: the site's identity certificate and the `GridNetwork` | all | [Grid](../hub/02-grid.md#grid-bootstrap) |
| A MaaS database replica, and the shared Redis for rate limits | ingress, combined | [MaaS shared services](../hub/03-maas-shared-services.md) |
| Submariner on every managed cluster; ACM's search collector on every site | every role | [ACM](../hub/01-acm.md) |
| Cluster sign-in and admins, and the Submariner gateway node labels | every managed cluster | [Platform services](../hub/00-platform-services.md#cluster-sign-in-and-admins) |
| Registry access (pull secret, image mirror) and the namespaces OpenShift AI needs | every managed cluster | [Site delivery](../hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites) |

## Pages

- [OpenShift AI on each site](openshift-ai.md): what each role installs, the tenant settings, and the GPU operator.
- [MaaS gateway certificate](maas-certificate.md): the certificate tenants see on each ingress or combined site.
- [Site networking](networking.md): load balancers, Submariner gateways and DNS.
