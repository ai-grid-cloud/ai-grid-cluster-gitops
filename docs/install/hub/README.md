# Hub and external dependencies

The hub runs everything the sites share and installs the sites. What it runs falls into two kinds:

- **Control plane:** items that are the ACM hub or act through it. They must run on the ACM hub.
- **Shared services:** services the sites call. They run on the hub by default, but can run on one site or, for some,
  be yours.

This part groups both into eight items, numbered in install order. Each item's page says what it is, your options,
what the example deployment chose, what it requires, and the lines that select it in your deployment repository
([select components](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/02-repositories.md#3-select-components)).

## Control plane: on the ACM hub

These items read or drive ACM: Argo CD targets sites through ACM placements, and the grid, site delivery, model
delivery and the console are ACM Policies, Placements and ApplicationSets on the hub.

| Item | What it is | Options | Requires | Example chose |
|---|---|---|---|---|
| [0. Platform services](00-platform-services.md) | OpenShift GitOps (Argo CD), cert-manager, External Secrets, cluster sign-in and admins, a default StorageClass | Each: ours, or the platform's or yours | A git host the hub can read; `cluster-admin` on the hub | Ours, except the platform's cert-manager |
| [1. ACM, the multicluster engine and Submariner](01-acm.md) | The hub's control plane, its observability, and the tunnels to the sites | Ours, or your existing ACM hub (partly) | Object storage: S4 or ODF on the hub, or any S3 bucket; a load balancer and two gateway nodes per cluster (cloud or MetalLB) | Ours, S4, AWS load balancers |
| [2. Grid](02-grid.md) | Grid bootstrap and enrollment, and the status policies | No choice (you can bring the CA) | cert-manager (0), ACM (1) | Ours, a new CA |
| [5. Provider console and model delivery](05-console-and-model-delivery.md) | The provider's admin UI, and delivery of the catalog to the sites | Console optional; model delivery required | Console: Keycloak with Organizations (4) and a token that can write only the catalog repository | Both |
| [6. Site delivery](06-site-delivery.md) | Site Placements, Argo CD registration, OpenShift AI's ApplicationSet, registry access | No choice | ACM (1); the `quay.io/rhoai` and stage logins (pre-release) | Ours |
| [7. Observability and usage logs](07-observability.md) | Dashboards for the console's **Monitoring** page, and MaaS usage logs | On or off | ODF object storage | Off |

## Shared services: on the hub, a site, or yours

The sites reach these over the network: the MaaS database and Redis through Submariner
(`*.svc.clusterset.local`), and the identity provider through its public URL. So they don't have to run on the hub.

| Item | What it is | Where it can run | Bring your own | Requires | Example chose |
|---|---|---|---|---|---|
| [3. MaaS shared services](03-maas-shared-services.md) | The MaaS database primary and the rate-limit Redis | The hub, or one site labelled `ai-grid/external-services=true` | Not yet ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)) | Submariner, to export them (1) | Ours, on the hub |
| [4. Tenant identity](04-tenant-identity.md) | The OIDC issuer for organization users | Our Keycloak on the hub or the `external-services` site, or your OIDC provider anywhere the sites reach | Yes | Ours: MaaS database (3), cert-manager and External Secrets (0). Yours: an OIDC issuer, a confidential client and its CA | Its own Keycloak, on the hub |

With the shared services on a site, other ingress sites get no database read replica or credentials yet
([external services](03-maas-shared-services.md#run-the-shared-services-on-a-site)). Object storage for ACM
observability is also outside the control plane: any S3 bucket works ([object storage](01-acm.md#object-storage)).

What the hub installs on each site is in [Spokes](../spokes/README.md).
