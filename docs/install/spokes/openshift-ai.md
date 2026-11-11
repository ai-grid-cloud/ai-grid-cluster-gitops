# OpenShift AI on each site

The hub installs OpenShift AI on each site in the site's role, from the odh-gitops `rhai-on-openshift-chart` Helm chart
that the library pins, and with it the operators OpenShift AI needs, including the NVIDIA GPU Operator and Node Feature
Discovery on inference and combined sites. You select the component once, on the hub
([site delivery](../hub/06-site-delivery.md)); per site you choose the role and, for ingress and combined sites, the
MaaS hostname prefix.
The example deployment's one site is `combined`, CPU only: the GPU operators are subscribed, with no GPU model.

## OpenShift AI with MaaS

This component installs OpenShift AI on each AI Grid site, in the site's role, from the `rhai-on-openshift-chart`
Helm chart that the library pins, and delivers the tenant settings (the AITenant and its OIDC client) to every site
that runs MaaS. [Model delivery](../hub/05-console-and-model-delivery.md#model-delivery), [AI Grid Policies](../hub/02-grid.md#ai-grid-policies) and the
[provider console](../hub/05-console-and-model-delivery.md#provider-console) depend on it.

| | |
|---|---|
| Runs on | hub (ApplicationSet and tenant Policy); ingress, inference and combined sites (OpenShift AI) |
| Library component | `apps/rhoai` (select `apps/rhoai/application.yaml`) |
| Choices | Use ours. Bring your own and Skip aren't options. |

### Use ours

1. Select `apps/rhoai/application.yaml` ([select it](../hub/06-site-delivery.md#select-it)).

   It reads the inputs `libraryRepoURL`, `libraryRevision`, `deploymentRepoURL`, `deploymentRevision` and all eight
   `idp*` inputs ([Appendix A](../appendix-a-inputs.md)). It needs [OpenShift AI prerequisites](../hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)
   and [spoke delivery](../hub/06-site-delivery.md#spoke-delivery).

2. Optional, for a site with role `ingress` or `combined`: to give its MaaS gateway a hostname prefix other than
   the library's default, `maas`, add `values/clusters/SITE/rhoai.yaml` to your deployment repository, and push it
   **before** you label the site:

   ```yaml
   components:
     aigateway:
       modelsAsAService:
         gateway:
           annotations:
             ai-grid/maas-gateway-hostname-prefix: HOSTNAME_PREFIX
   ```

   Replace the following:

   - `SITE`: the site's ManagedCluster name.
   - `HOSTNAME_PREFIX`: the first label of the MaaS host name. Tenants call `https://HOSTNAME_PREFIX.APPS_DOMAIN`,
     where `APPS_DOMAIN` is the site's ingress domain. The example deployment uses `maas`.

   An `inference` site needs no file. To give the MaaS gateway a publicly trusted certificate, add an HTTPS listener
   override to the same file; see [MaaS gateway certificate](maas-certificate.md).

3. Create the two hub objects the `idp*` inputs name: the Secret holding the tenant client's secret, and the
   ConfigMap holding the CA that signs the issuer's certificate. [Tenant identity provider](../hub/04-tenant-identity.md#tenant-identity-provider) covers both. The
   component reads only those two objects, by name, through a dedicated ServiceAccount.

4. Label the site ([Join the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md)). The `rhoai` ApplicationSet then generates one Application
   per site, named `rhoai-SITE-HASH`, from three layers: the library's `apps/rhoai/values.yaml`, the role file
   `apps/rhoai/roles/ROLE.yaml`, and your `values/clusters/SITE/rhoai.yaml`.

What each role installs:

| Role | Installs | Not installed |
|---|---|---|
| `ingress` | OpenShift AI with MaaS, the MaaS gateway `openshift-ingress/maas-default-gateway`, the grid consumer gateway, the MaaS portal and dashboard, the tenant settings | KServe, models *(Unverified.)* |
| `inference` | OpenShift AI with KServe, the grid operator and provider gateway | MaaS, dashboards *(Unverified.)* |
| `combined` | Both | |

On every ingress and combined site, Policy `redhat-ai-grid/rhoai-ingress-clusters` on the hub delivers the tenant
settings from the `idp*` inputs:

| Input | Lands on the site as |
|---|---|
| `idpIssuerURL` | `spec.oidc.issuerUrl` of AITenant `ai-tenants/models-as-a-service` |
| `idpClientID` | `spec.oidc.clientId` and `spec.oidc.audience` of that AITenant; MaaS matches the token's `azp` against it |
| `idpClientSecretNamespace`, `idpClientSecretName`, `idpClientSecretKey` | Secret `models-as-a-service/tenant-demo-oidc-client`, key `clientSecret` |
| `idpCANamespace`, `idpCAName`, `idpCAKey` | ConfigMap `kuadrant-system/home-keycloak-ca`, key `home-keycloak-ca.crt`, mounted into Authorino |

The same Policy creates MaasTenantConfig `models-as-a-service/default-tenant` and the grid `ExternalProvider`
`grid-provider` that sends MaaS traffic into the grid. Each `rhoai-*` Application carries the annotation
`ai-grid/library-revision` with the library commit the site runs.

#### Verify

On the hub, list each site's Application and its library commit, and the tenant Policy's compliance:

```sh
oc -n openshift-gitops get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,REVISION:.metadata.annotations.ai-grid/library-revision,SYNC:.status.sync.status,HEALTH:.status.health.status' |
  grep -E '^(NAME|rhoai-)'
oc -n SITE get policies | grep rhoai-ingress-clusters
```

You should see each `rhoai-*` Application `Synced` and `Healthy` with your pinned commit, and the Policy `Compliant`.

On the site, check OpenShift AI and, for ingress or combined sites, MaaS:

```sh
oc get datasciencecluster default-dsc
oc -n openshift-ingress get gateway maas-default-gateway
oc -n ai-tenants get aitenant models-as-a-service
```

You should see the DataScienceCluster `Ready`. It takes 45 to 60 minutes after you label the site. On an
inference site, the DataScienceCluster can stay not `Ready` while KServe and the grid are up; use the
`ai-grid-ready` Policy instead ([AI Grid Policies](../hub/02-grid.md#ai-grid-policies)). *(Unverified.)* The gateway lists the
host name `HOSTNAME_PREFIX.APPS_DOMAIN` on both listeners.

### Bring your own

Not an option: the grid, the catalog and the console expect the chart's profiles, namespaces and object names. You
choose the tenant IdP through the `idp*` inputs, and you can override chart values per site in
`values/clusters/SITE/rhoai.yaml`. Helm replaces lists whole, so an override of a list repeats every entry.

### Skip

You can't skip it: it's what makes a cluster an AI Grid site.

### Upgrade

The chart version (`3.6.0-dev.32.1`) and the OpenShift AI catalog image (`apps/rhoai/nightly.yaml`) are pinned in
the library, so they move only with the library pin. A pin move rolled every site's Application in about 6 minutes
with no manual step; the `ai-grid/library-revision` annotation shows when each site has moved.

### Known issues

**Symptom:** a site's `rhoai-*` Application fails to render with
`...ai-grid/maas-gateway-hostname-prefix is required`.
**Cause:** the site is ingress or combined and its `values/clusters/SITE/rhoai.yaml` sets an empty hostname prefix.
**Workaround:** set a prefix in the file (step 2 of [Use ours](#use-ours)) and push it; the Application renders on its
next refresh.

MaaS gateway certificate errors and the cleartext port 80 listener are on the
[MaaS gateway certificate](maas-certificate.md#known-issues) page.

**Symptom:** tenant calls fail with 401 or 503 after the IdP was down or rotated its keys, though the IdP is back.
**Cause:** Authorino cached the failed OIDC discovery.
**Workaround:** on the site, restart Authorino: `oc -n kuadrant-system rollout restart deployment authorino`.

**Symptom:** the Org UI signs a tenant in, then can't load models ("Unable to load MaaS models") or API keys; its
calls return 401.
**Cause:** OpenShift AI 3.6 nightlies before FBC `d0ee30a` send the
portal's token in the wrong header ([RHAI-21554](https://redhat.atlassian.net/browse/RHAI-21554)).
**Workaround:** pin FBC `d0ee30a` or later; until then, create API keys through the MaaS API
([tenant access](../tenant-access.md#create-an-api-key-and-call-with-it)).

**Symptom:** about one call in six fails the TLS handshake or hangs.
**Cause:** an address of the gateway's load balancer is in a zone with no gateway pod (infrastructure).
**Workaround:** fix the load balancer's zones, or run gateway pods in every zone it serves.

## NVIDIA GPU Operator and Node Feature Discovery

The NVIDIA GPU Operator installs the drivers and device plugin that let models request NVIDIA GPUs, and Node Feature
Discovery (NFD) labels the nodes it needs. Models that run on GPUs depend on both; CPU-only sites serve small sample
models without them.

| | |
|---|---|
| Runs on | inference and combined sites with NVIDIA GPUs |
| Library component | None directly. [OpenShift AI](#openshift-ai-with-maas) (`apps/rhoai`) subscribes both operators on inference and combined sites; their configuration is yours |
| Choices | Use ours (operators from `apps/rhoai`, configuration yours) · Bring your own · Skip (CPU-only sites) |

Most of this section is unverified: the verified install ran a CPU model on a site without GPUs.

### Use ours

The OpenShift AI chart that `apps/rhoai` installs (`rhai-on-openshift-chart`, profile `ai-grid-inference`, which the
`ai-grid-combined` profile extends) turns on two dependencies on every inference and combined site:

| Operator | Package | Namespace | Channel | Catalog |
|---|---|---|---|---|
| NFD | `nfd` | `openshift-nfd` | `stable` | `redhat-operators` |
| NVIDIA GPU Operator | `gpu-operator-certified` | `nvidia-gpu-operator` | `v25.10` | `certified-operators` |

The chart creates the `NodeFeatureDiscovery` and `ClusterPolicy` resources only when you give their spec, and the
library doesn't. Until you do, the operators run but no driver is installed and no node offers `nvidia.com/gpu`.
Ingress sites get neither operator.

1. Make sure each GPU site can pull from the `certified-operators` catalog.
2. Give each GPU site the two specs in its file in your deployment repository, `values/clusters/SITE/rhoai.yaml`,
   which the `rhoai` Application reads after the role's values. *(Unverified.)*

   ```yaml
   dependencies:
     nfd:
       config:
         spec: {}            # your NodeFeatureDiscovery spec
     nvidiaGPUOperator:
       config:
         spec: {}            # your ClusterPolicy spec
   ```

   Replace `SITE` with the ManagedCluster name, and each `{}` with a spec from the
   [NFD](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/specialized_hardware_and_driver_enablement/psap-node-feature-discovery-operator)
   and [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/)
   documentation. The chart renders `NodeFeatureDiscovery` `nfd-instance` and `ClusterPolicy` `gpu-cluster-policy`
   once the operators' CRDs exist, so the first sync after a site joins may need a second sync.

   Alternatively, create those two resources yourself on each site, outside the library.

#### Verify

```sh
oc --context SITE_CONTEXT -n openshift-nfd get csv
oc --context SITE_CONTEXT -n nvidia-gpu-operator get csv,clusterpolicy
oc --context SITE_CONTEXT get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

Replace `SITE_CONTEXT` with your kubeconfig context for the site.

You should see both operators' CSVs `Succeeded`, ClusterPolicy `gpu-cluster-policy` `ready`, and each GPU node with a
non-zero GPU count. *(Unverified.)*

### Bring your own

If a site already runs NFD and the GPU Operator, the contract is: nodes with GPUs advertise allocatable
`nvidia.com/gpu`, and the operators are installed in `openshift-nfd` and `nvidia-gpu-operator` with the package names
in the table. The chart's Subscriptions use the same package names and namespaces, so OLM sees one operator; a
Subscription with another name for the same package in the same namespace can conflict. *(Unverified.)*

To stop the chart from managing them on a site, set both off in that site's `values/clusters/SITE/rhoai.yaml`. The
chart lets explicit values override the profile, but the library doesn't test this ([gaps](../known-gaps.md)).
*(Unverified.)*

```yaml
dependencies:
  nfd:
    enabled: false
  nvidiaGPUOperator:
    enabled: false
```

Check with the verify commands.

### Skip

A site without GPUs works for CPU models: the verified install served SmolLM2-135M-Instruct on CPU through the grid.
The operators are still subscribed on inference and combined sites, and with no `ClusterPolicy` they install nothing
on the nodes. What stops working: any model whose runtime asks for `nvidia.com/gpu` stays `Pending` on that site. The
console's model runtime defaults to NVIDIA GPUs, so give CPU-only sites a CPU runtime image when you deploy.

### Upgrade

The chart version, and with it each operator's channel, moves with the library pin. Within a channel, OLM upgrades the
operators automatically. Your specs in `values/clusters/SITE/rhoai.yaml` stay as they are.

### Known issues

- **Symptom:** GPU nodes show no `nvidia.com/gpu` capacity although the GPU Operator is installed.
  **Cause:** The library sets no `ClusterPolicy` spec, so the chart creates none.
  **Workaround:** Give the spec as in [Use ours](#use-ours-1), or create the `ClusterPolicy` yourself. *(Unverified.)*
