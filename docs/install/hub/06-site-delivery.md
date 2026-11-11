# Site delivery

Site delivery is how the hub installs the [spokes](../spokes/README.md): Placements that turn each ManagedCluster's
`ai-grid/enabled` and `ai-grid/role` labels into sites, Argo CD registration of every managed cluster, the OpenShift AI
ApplicationSet, and the registry access and namespaces every cluster needs before OpenShift AI installs.

| | |
|---|---|
| Options | No choice |
| Example chose | Ours |
| Requires | [ACM](01-acm.md); OpenShift GitOps's settings (`apps/gitops-config`, [platform services](00-platform-services.md)); the `quay.io/rhoai` and `registry.stage.redhat.io` logins (pre-release, [before you start](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/01-before-you-start.md)); the grid ([grid bootstrap](02-grid.md)) and the tenant identity inputs ([tenant identity](04-tenant-identity.md)) for OpenShift AI |

## Select it

```yaml
- path: apps/ai-grid-spokes/application.yaml
- path: apps/argo-registration/application.yaml
- path: apps/rhoai/application.yaml
- path: apps/rhoai-prerequisites/application.yaml
```

Registry access can't be skipped yet: the `quay.io/rhoai` pull secret, the catalog pull secret and the image mirror ride
in `apps/rhoai-prerequisites` with what every install needs ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).

## OpenShift AI on the sites

`apps/rhoai` is selected here, on the hub, and installs OpenShift AI on each site in its role. What it installs, and
the per-site values it reads, are in [Spokes](../spokes/README.md) and
[OpenShift AI on each site](../spokes/openshift-ai.md).

## Spoke delivery

These two components decide which clusters are AI Grid sites and let Argo CD on the hub reach them. `apps/ai-grid-spokes`
turns the `ai-grid/enabled` and `ai-grid/role` labels on each ManagedCluster into ACM Placements, and
`apps/argo-registration` registers every managed cluster with Argo CD. [OpenShift AI](../spokes/openshift-ai.md#openshift-ai-with-maas),
[model delivery](05-console-and-model-delivery.md#model-delivery), [AI Grid Policies](02-grid.md#ai-grid-policies) and the per-site parts of other
components all select sites through these Placements.

| | |
|---|---|
| Runs on | hub |
| Library component | `apps/ai-grid-spokes` and `apps/argo-registration` (select both `application.yaml` files) |
| Choices | Use ours. Bring your own and Skip aren't options. |

### Use ours

1. Select `apps/ai-grid-spokes/application.yaml` and `apps/argo-registration/application.yaml` ([select it](#select-it)).

   They read the inputs `libraryRepoURL` and `libraryRevision`, and no file from your deployment repository. Argo
   CD's `global` ManagedClusterSetBinding in `openshift-gitops` comes from `apps/gitops-config`
   ([OpenShift GitOps](00-platform-services.md#openshift-gitops)), so select that too.

2. Make a cluster a site by labelling its ManagedCluster on the hub ([Join the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md)):

   ```sh
   oc label managedcluster SITE ai-grid/enabled=true ai-grid/role=ROLE location=LOCATION
   ```

   Replace the following:

   - `SITE`: the ManagedCluster name.
   - `ROLE`: `ingress`, `inference` or `combined`.
   - `LOCATION`: a name for where the site runs, such as `us-east`.

   For an `ingress` or `combined` site, push `values/clusters/SITE/rhoai.yaml` first ([OpenShift AI](../spokes/openshift-ai.md#openshift-ai-with-maas)).

How it works:

- `apps/argo-registration` creates GitOpsCluster `argo-registration`, which gives every managed cluster an Argo CD
  cluster Secret carrying its labels. Tolerations keep a briefly unreachable cluster registered.
- `apps/ai-grid-spokes` creates three Placements, each in both `openshift-gitops` (for ApplicationSets) and
  `ai-grid-policies` (for Policies):

  | Placement | Selects `ai-grid/enabled=true` and `ai-grid/role` in |
  |---|---|
  | `ai-grid-spokes` | `ingress`, `inference`, `combined` |
  | `ai-grid-ingress` | `ingress`, `combined` |
  | `ai-grid-inference` | `inference`, `combined` |

- Each ApplicationSet that targets sites, such as `rhoai`, reads a Placement's decisions live and joins them with
  the cluster's Argo CD Secret for its server address and role. It never selects on the Secret's labels alone,
  because ACM copies labels onto that Secret but never removes one.

A cluster with `ai-grid/enabled=true` and no role, or an unknown role, matches no Placement and gets none of the AI
Grid platform. Grid bootstrap reads `ai-grid/enabled` alone, so such a cluster still becomes a grid member whose
enrollment waits for grid CRDs that never arrive: always set both labels. The
[README](../../../apps/ai-grid-spokes/README.md) has the full rules.

#### Verify

On the hub:

```sh
oc -n openshift-gitops get placementdecisions \
  -l 'cluster.open-cluster-management.io/placement in (ai-grid-spokes,ai-grid-ingress,ai-grid-inference)' \
  -o custom-columns='PLACEMENT:.metadata.labels.cluster\.open-cluster-management\.io/placement,CLUSTERS:.status.decisions[*].clusterName'
oc -n openshift-gitops get secrets -l apps.open-cluster-management.io/acm-cluster=true
oc -n openshift-gitops get applications.argoproj.io | grep SITE
```

You should see each site under the Placements its role selects, one Argo CD cluster Secret per managed cluster, and
the site's Applications (`rhoai-*` and the others) a minute or two after you label it.

#### Remove a site

To remove a site from AI Grid management, remove its `ai-grid/enabled` label (the console's **Remove** does the same):

```sh
oc label managedcluster SITE ai-grid/enabled-
```

The site leaves the Placements, and its Applications go at the next poll: on the tested hub, within 30 seconds, and
the `maas-db` replica's Application about 3 minutes later. The console shows the site as **Not added**.

- Not withdrawn: grid membership. On the tested site the GridSite stayed `Connected` and `Available` for the whole
  7 minutes it was unlabelled. Withdrawing a site from the grid isn't designed yet
  ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).
- Stays installed, no longer managed: OpenShift AI, the provider gateway and the catalog's models, because the
  ApplicationSets set `preserveResourcesOnDeletion`.
- Deleted: the site's `maas-db` replica, and the catalog's MaaS objects and subscriptions on that site, so no tenant
  access outlives the site's membership.
- Stays and needs cleanup: the Secrets Policies delivered (`maas-db-config`, `maas-db-app`, `maas-db-replication`)
  and the tenant objects. Rotate the shared credentials after you remove a site.

Applications that go to every managed cluster, such as Submariner, stay until you detach the cluster from ACM.
Removing only the role has the same effect on the platform; either way the cluster stays a grid member.

### Bring your own

Not an option: the library's ApplicationSets and Policies name these Placements.

### Skip

You can't skip them: without them no cluster becomes a site and Argo CD can't deliver to any cluster.

### Upgrade

Both components move with the library pin and need no manual step.

### Known issues

**Symptom:** a site's Application renders the old role's values for up to a minute after a role change.
**Cause:** the Placements see the new role at once, and the Argo CD cluster Secret's labels follow a few seconds later.
**Workaround:** none needed; the Application converges at the next poll.

## Registry access and OpenShift AI prerequisites

> **Important:** This release installs pre-release OpenShift AI 3.6 builds. Every cluster pulls them from
> `quay.io/rhoai`, and the image mirror the library delivers sends every `registry.redhat.io/rhaii*` image, model
> runtimes included, to `registry.stage.redhat.io` with `NeverContactSource`. You need logins for both registries,
> which Red Hat gives only to early-access partners; ask your Red Hat contact. Without a stage login, model images fail
> to pull on every site. What changes at general availability (the catalog source, the mirror, which logins you need)
> isn't decided in the library yet ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).

This component delivers, through ACM Policies on the hub, what every managed cluster needs before OpenShift AI installs
there: protected namespaces, the model namespace and its NetworkPolicies, the image mirror, the catalog pull secret and
the merged cluster pull secret. OpenShift AI 3.6 pre-release builds come from `quay.io/rhoai`, which needs a login, and
their images keep their `registry.redhat.io` names, so every cluster needs that login and an image mirror. You give the
login once, on the hub, and this component delivers it and the mirror to every managed cluster.
[OpenShift AI](../spokes/openshift-ai.md#openshift-ai-with-maas), [model delivery](05-console-and-model-delivery.md#model-delivery), every model image and the shared Limitador counters
(`apps/limitador-redis`) depend on it.

| | |
|---|---|
| Runs on | hub (Policies and the registry credential); delivered to every managed cluster in the `global` cluster set, the hub included |
| Library component | `apps/rhoai-prerequisites` (select `apps/rhoai-prerequisites/application.yaml`); the registry credential is infrastructure you provide |
| Choices | Use ours. Bring your own applies only to the registry credentials. Skip isn't an option. |

### Use ours

1. Select `apps/rhoai-prerequisites/application.yaml` ([select it](#select-it)).

   It reads the `libraryRepoURL` and `libraryRevision` inputs only, and no file from your deployment repository.

2. Get a `quay.io` login that can pull the `quay.io/rhoai` repositories. Prefer a robot account scoped to
   `quay.io/rhoai`. Sign in with it so your container auth file holds a `quay.io/rhoai` entry:

   ```sh
   podman login quay.io/rhoai
   ```

3. Add a `registry.stage.redhat.io` login to the same auth file before you run the bootstrap script:
   `podman login registry.stage.redhat.io`. The mirror sends every `registry.redhat.io/rhaii*` image, model runtimes
   included, there and never contacts the source, so every site needs it. `bootstrap-hub.sh` passes it to
   `create-hub-secret.sh` as `RHOAI_STAGE_PULL_SECRET`, and warns when the auth file has none. *(Unverified: the
   tested site already had the model image.)*

4. Run the library's [`scripts/bootstrap-hub.sh`](../../../scripts/bootstrap-hub.sh) with the auth file, from your
   deployment checkout:

   ```sh
   KUBECONFIG=HUB_KUBECONFIG RHOAI_QUAY_AUTH_FILE=AUTH_FILE ../library/scripts/bootstrap-hub.sh --deployment .
   ```

   Replace the following:

   - `HUB_KUBECONFIG`: a kubeconfig with a `cluster-admin` session on the hub.
   - `AUTH_FILE`: your container auth file, such as `${XDG_RUNTIME_DIR}/containers/auth.json` or
     `~/.config/containers/auth.json`.

   The script reads the `quay.io/rhoai` entry, never prints it, and runs the library's
   [`create-hub-secret.sh`](../../../apps/rhoai-prerequisites/create-hub-secret.sh). That creates Secret
   `rhoai-prerequisites/rhoai-quay-pull-secret` (type `kubernetes.io/dockerconfigjson`, key `.dockerconfigjson`)
   on the hub. Nothing goes into git.

   If your auth file has only a general `quay.io` login, the script stops. To use that login anyway, set
   `RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1`. The hub Secret then holds your general `quay.io` credential, although the
   Policy writes it to each cluster only as a `quay.io/rhoai` entry.

   Until the hub Secret exists, the pull-secret Policy renders nothing and changes no cluster; the image mirror is
   delivered anyway.

Argo CD creates namespace `rhoai-prerequisites` on the hub, a `global` ManagedClusterSetBinding, Placements and these
Policies:

| Policy | Where | What it delivers |
|---|---|---|
| `rhoai-prerequisites` | every managed cluster, hub included | Namespaces `redhat-ai-grid`, `redhat-ods-operator` and `ai-grid-internal-models`; the model namespace's NetworkPolicies; the model-publisher RBAC; ImageDigestMirrorSet `quay-registry`; Secret `openshift-marketplace/rhoai-catalog-pull-secret`; the hub's registry entries merged into `openshift-config/pull-secret`; the service CA as Secret `redhat-ai-grid/openshift-service-ca` |
| `rhoai-limitador-redis` | ingress and combined sites other than the hub | Namespace `limitador-redis`, Secret `kuadrant-system/limitador-redis`, and the `Limitador` Redis storage reference, so MaaS rate-limit counters are shared through Submariner |
| `rhoai-maas-api-metrics` | ingress and combined sites | Compatibility monitors for MaaS metrics |
| `rhoai-otel-cert-manager-compat` | AI Grid sites | Temporary cert-manager permissions for the OpenTelemetry operator |
| `rhoai-metrics-addon`, `rhoai-metrics-network` | hub; AI Grid sites | Metrics add-on registration; NetworkPolicy admitting ACM's agents to the collector on port 8889 |

The registry pieces of the `rhoai-prerequisites` Policy:

- Secret `openshift-marketplace/rhoai-catalog-pull-secret`, for the OpenShift AI catalog image.
- The hub Secret's registries merged into `openshift-config/pull-secret`. Existing entries stay; the hub's win for
  the registries it holds. A bare `quay.io` entry in the hub Secret lands only as `quay.io/rhoai`, so the cluster's own
  `quay.io` login stays.
- ImageDigestMirrorSet `quay-registry`: `registry.redhat.io/rhoai` from `quay.io/rhoai`, and
  `registry.redhat.io/rhaii`, `rhaii-early-access` and `rhaii-fast` from `registry.stage.redhat.io`, all with
  `mirrorSourcePolicy: NeverContactSource`.

Neither delivery drains or reboots nodes. The Machine Config Operator writes the new pull secret and `registries.conf`
to each node and reloads CRI-O: a pull secret change never needs a drain or reboot, and adding mirrors that are
digest-only, as an ImageDigestMirrorSet's are, skips the drain ([OpenShift 4.22, Machine configuration, "About the Machine Config Operator"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/machine_configuration/index#about-machine-config-operator_machine-config-overview); the same in 4.21). On the tested site the
first delivery logged `Changes do not require drain, skipping` and `crio service reloaded` on every node, and no
node restarted. Removing or changing a mirror later does drain the nodes, one at a time.

The [README](../../../apps/rhoai-prerequisites/README.md) has the details, including the OpenTelemetry workaround.

#### Verify

On the hub, check that the Secret exists without showing its data, and that the Policies are compliant:

```sh
oc -n rhoai-prerequisites get secret rhoai-quay-pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
oc -n rhoai-prerequisites get policies
oc -n SITE get policies | grep rhoai-prerequisites
```

Replace `SITE` with the ManagedCluster name of a site.

You should see Secret type `kubernetes.io/dockerconfigjson`, and each Policy `Compliant`. A cluster's
`rhoai-prerequisites` Policy can stay `NonCompliant` for a few minutes while its MachineConfigPools apply the new
pull secret and mirror. *(Unverified.)*

On the site, check the namespaces, the mirror and the pull secret, without showing any credential:

```sh
oc --context SITE_CONTEXT get namespace redhat-ai-grid redhat-ods-operator ai-grid-internal-models
oc --context SITE_CONTEXT get imagedigestmirrorset quay-registry
oc --context SITE_CONTEXT -n openshift-config get secret pull-secret \
  -o go-template='{{index .data ".dockerconfigjson" | base64decode}}' | jq -r '.auths | keys[]'
oc --context SITE_CONTEXT get machineconfigpool
```

Replace `SITE_CONTEXT` with your kubeconfig context for a site.

You should see the three namespaces `Active`, the mirror present, `quay.io/rhoai` among the registry names (the
command prints names only), and every MachineConfigPool `UPDATED` `True` once the rollout finishes.

### Bring your own

The namespaces, NetworkPolicies and RBAC aren't replaceable: the OpenShift AI and model components rely on them by
name. You can supply the registry credentials another way. Two cases:

- **You create the hub Secret yourself.** Create `rhoai-prerequisites/rhoai-quay-pull-secret`, type
  `kubernetes.io/dockerconfigjson`, whose `.dockerconfigjson` has an `auths` entry `quay.io/rhoai` or `quay.io`, and
  optionally other registries. Use `create-hub-secret.sh` with `RHOAI_QUAY_PULL_SECRET` (base64 of
  `USERNAME:PASSWORD`) read from the terminal, so the value isn't in your shell history:

  ```sh
  read -s RHOAI_QUAY_PULL_SECRET && export RHOAI_QUAY_PULL_SECRET
  HUB_CONTEXT=HUB_CONTEXT bash LIBRARY_CHECKOUT/apps/rhoai-prerequisites/create-hub-secret.sh
  ```

  Replace `HUB_CONTEXT` with your hub's kubeconfig context and `LIBRARY_CHECKOUT` with a checkout of the library at
  your pinned commit.

- **Your clusters already have the credentials and mirror** (for example, a disconnected install with its own mirror
  registry). If every cluster's `openshift-config/pull-secret` already holds a `quay.io/rhoai` login and each cluster
  has its own `openshift-marketplace/rhoai-catalog-pull-secret`, leave the hub Secret out and the pull-secret Policy
  changes nothing. *(Unverified.)* The Policy still delivers ImageDigestMirrorSet `quay-registry`, which can conflict
  with your own mirrors. The library has no switch to turn it off. *(Unverified.)*

### Skip

You can't skip it. While the library installs OpenShift AI 3.6 pre-release builds, without the login the catalog image
and operator bundles don't pull, and OpenShift AI never installs on any site. Without the namespaces, models have no
namespace to run in.

### Upgrade

The component, the mirror and the Policies move with the library pin and need no manual step. To rotate the
credential, run `create-hub-secret.sh` again; ACM copies the new value to every cluster, and the hub's value wins over
the old one. Deleting the hub Secret doesn't remove credentials already on the clusters.

### Known issues

- **Symptom:** A site's nodes go `SchedulingDisabled` one by one after you change or remove the image mirror.
  **Cause:** Changing or removing `registries.conf` entries makes the Machine Config Operator drain each node; only
  adding digest-only mirrors skips the drain.
  **Workaround:** None needed; wait for every MachineConfigPool to report `UPDATED` `True`.
