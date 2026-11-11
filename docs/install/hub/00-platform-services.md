# Platform services

The platform services are the hub's foundation: OpenShift GitOps (Argo CD), which installs everything else in this
part, cert-manager, the External Secrets Operator, and the hub's own sign-in and storage. For each one, use the
library's, or the one your platform already runs.

| Service | What it does | Options | Example chose |
|---|---|---|---|
| [OpenShift GitOps](#openshift-gitops) | Installs every component from git | Ours · yours | ours |
| [cert-manager](#cert-manager) | Issues the grid CA, Keycloak's signing keys and OpenShift AI's monitoring certificates; usually also the MaaS gateway certificates | Ours · the platform's | the platform's |
| [External Secrets](#external-secrets-operator) | Generates S4's keys and Keycloak's passwords, so no secret goes in git | Ours · yours · skip, if nothing needs it | ours |
| [Cluster sign-in and admins](#cluster-sign-in-and-admins) | `cluster-admin` on the hub and every site, the break-glass admin, the Submariner gateway node labels | Ours (`cluster-config`) · your own RBAC (still select `cluster-config`) | ours |
| [Default StorageClass](#default-storageclass) | Volumes for ACM observability, the databases, Redis and S4 | The platform's | the platform's |

Requires:

- A git host the hub's Argo CD can read, with your deployment and catalog repositories
  ([create your repositories](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/README.md#start-here)).
- `cluster-admin` on the hub ([before you start](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/01-before-you-start.md#3-accounts-and-credentials)).

## Select it

Add these lines to the `files` list in your `root/kustomization.yaml`
([select components](README.md#select-components)):

```yaml
- path: apps/gitops-config/application.yaml
- path: cluster-config/application.yaml
- path: apps/external-secrets/application.yaml
```

Add `- path: apps/cert-manager/application.yaml` only if the hub doesn't run cert-manager already. The OpenShift GitOps
operator itself isn't a line: the bootstrap script installs it.

## OpenShift GitOps

OpenShift GitOps (Argo CD) on the hub installs every AI Grid component from git: the library at your pinned commit,
your deployment repository, and the catalog. Every other component depends on it, and ACM's GitOps integration
(`apps/argo-registration`) uses it to reach the sites.

| | |
|---|---|
| Runs on | hub |
| Library component | Operator: the library's `bootstrap/` files, applied once by your bootstrap script. Configuration: `apps/gitops-config` (select `apps/gitops-config/application.yaml`) |
| Choices | Use ours · Bring your own |

### Use ours

1. Install the operator and the root with the library's
   [`scripts/bootstrap-hub.sh`](../../../scripts/bootstrap-hub.sh), described in
   [Prepare the hub](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/03-prepare-hub.md). For OpenShift GitOps it does the following, from the library at the
   commit your root pins:

   1. Applies `bootstrap/namespace.yaml`, `bootstrap/gitops-operator-group.yaml` and
      `bootstrap/openshift-gitops-sub.yaml`: namespace `openshift-gitops-operator` and Subscription
      `openshift-gitops-operator` (channel `latest`, catalog `redhat-operators`, automatic approval).
   2. Waits for the `applications.argoproj.io` and `applicationsets.argoproj.io` CRDs, and for the default instance,
      ArgoCD `openshift-gitops` in namespace `openshift-gitops`, to reach phase `Available`.
   3. Applies `bootstrap/openshift-gitops-admin.yaml`: ClusterRoleBinding `openshift-gitops-admin`, which binds
      `cluster-admin` to ServiceAccount `openshift-gitops/openshift-gitops-argocd-application-controller`.
   4. Applies your `root/` (the root ApplicationSet `apps`). From then on Argo CD follows git.

2. Select `apps/gitops-config/application.yaml` ([select it](#select-it)).

   It reads the `libraryRepoURL` and `libraryRevision` inputs and no file from your deployment repository. It
   server-side applies these fields onto ArgoCD `openshift-gitops`, and owns only them:

   - The application controller's memory: request `2Gi`, limit `8Gi`. The controller caches the in-cluster
     destination and every site, and runs out of memory with less during start-up and fan-out.
   - `resourceHealthChecks` for the kinds AI Grid deploys, such as CloudNativePG `Cluster`, `ExternalSecret`,
     OLM `Subscription`, `DataScienceCluster`, `GridNetwork`, `InferenceProvider`, `ManagedClusterAddOn`,
     `LLMInferenceService`, `ExternalModel` and `MaaSModelRef`. Without them, Argo CD reports these as Healthy before
     they are ready, and sync waves don't wait.

   It also creates ManagedClusterSetBinding `openshift-gitops/global`, so Placements in `openshift-gitops` can
   select clusters from the `global` cluster set. That object needs ACM's CRDs, so the Application retries until
   [ACM](01-acm.md#red-hat-advanced-cluster-management) is installed.

The Application never prunes, so removing it doesn't delete the ArgoCD instance.

#### Verify

On an ACM hub, `oc get application` resolves to ACM's kind, so name the Argo CD kind in full:

```sh
oc -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}{"\n"}'
oc -n openshift-gitops get argocd openshift-gitops \
  -o jsonpath='{.spec.controller.resources.limits.memory}{"\n"}'
oc -n openshift-gitops get applications.argoproj.io gitops-config
oc -n openshift-gitops get applicationset apps \
  -o jsonpath='{.status.conditions[?(@.type=="ParametersGenerated")].status}{"\n"}'
```

You should see `Available`, `8Gi`, `gitops-config` `Synced` and `Healthy`, and `True`.

### Bring your own

You can use an Argo CD instance you already run, if it meets this contract. Every library Application and
ApplicationSet is written for it. *(Unverified.)*

- **Namespace and name.** The instance is ArgoCD `openshift-gitops` in namespace `openshift-gitops`, managed by the
  OpenShift GitOps operator. Every library Application names `namespace: openshift-gitops`, and `apps/gitops-config`
  patches the ArgoCD CR by that name.
- **Permissions.** The application controller can create any resource on the hub. The library grants
  `cluster-admin` to `openshift-gitops-argocd-application-controller`; a narrower role fails on cluster-scoped
  objects such as ClusterRoleBindings, Policies and Subscriptions.
- **ApplicationSet controller.** Enabled, with Go templates, `templatePatch` and the `clusterDecisionResource`,
  `matrix`, `clusters` and `git` generators. The root fails with `missing input: <name>` through `templatePatch`, so
  an older controller that ignores it creates broken Applications instead of failing.
- **ACM integration.** `apps/argo-registration` creates a GitOpsCluster that writes one cluster Secret per managed
  cluster into `openshift-gitops`, labelled `apps.open-cluster-management.io/acm-cluster=true`. The
  `clusterDecisionResource` generators read ConfigMap `openshift-gitops/acm-placement`.
- **Health checks and sizing.** Select `apps/gitops-config` so it applies the controller memory and health checks
  onto your instance. If your instance isn't operator-managed, copy the `resourceHealthChecks` from
  [`apps/gitops-config/manifests/argocd.yaml`](../../../apps/gitops-config/manifests/argocd.yaml) into its
  configuration yourself.
- **Repository access.** The instance can read the library, your deployment repository and your catalog repository.

Check the instance and the controller's permissions:

```sh
oc -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}{"\n"}'
oc auth can-i '*' '*' --all-namespaces \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
oc -n openshift-gitops get configmap acm-placement
```

You should see `Available` and `yes`. The ConfigMap appears after ACM and `apps/argo-registration` are installed.

### Skip

You can't skip it. Without Argo CD on the hub, no component installs.

### Upgrade

The operator follows its Subscription (channel `latest`, automatic approval), not the library pin: OLM upgrades it
when Red Hat publishes a new version. The bootstrap files aren't applied again after the first install. Moving the pin
updates `apps/gitops-config`'s health checks and sizing with no manual step.

### Known issues

- **Symptom:** `oc get application gitops-config` returns `NotFound` or an ACM object.
  **Cause:** ACM also defines a kind named `Application`.
  **Workaround:** Use `applications.argoproj.io`.
- **Symptom:** The application controller restarts with `OOMKilled` as sites join.
  **Cause:** The controller caches every destination.
  **Workaround:** Select `apps/gitops-config`. A hub with many sites can need more than `8Gi`; raise the limit with a
  patch in your deployment. *(Unverified.)*

## cert-manager

cert-manager issues the certificates AI Grid creates for itself: the grid CA and each site's identity certificate
(grid enrollment, `apps/grid-bootstrap`), the library Keycloak's signing keys, and OpenShift AI's monitoring
certificates on the sites. It's also the usual way to give the MaaS gateway a certificate your tenants trust; see
[MaaS gateway certificate](../spokes/maas-certificate.md).

| | |
|---|---|
| Runs on | hub; ingress, inference and combined sites |
| Library component | Hub: `apps/cert-manager` (select `apps/cert-manager/application.yaml`). Sites: installed by [OpenShift AI](../spokes/openshift-ai.md#openshift-ai-with-maas) |
| Choices | Use ours · Bring your own (the platform's cert-manager Operator for Red Hat OpenShift) |

### Use ours

On the hub:

1. Select `apps/cert-manager/application.yaml` ([select it](#select-it)).

   It reads the `libraryRepoURL` and `libraryRevision` inputs and no file from your deployment repository. It needs no
   Secret.

2. Argo CD creates namespace `cert-manager-operator`, OperatorGroup `openshift-cert-manager-operator` and
   Subscription `openshift-cert-manager-operator` (channel `stable-v1`, catalog `redhat-operators`, automatic
   approval). It creates no ClusterIssuer. *(Unverified: the verified install used the platform's cert-manager.)*

Don't select it on a hub that already runs the cert-manager operator: a second OperatorGroup in
`cert-manager-operator` makes OLM fail every operator in that namespace.

On the sites you do nothing: the OpenShift AI chart installs the same operator as a dependency of KServe and AI
Gateway (`dependencies.certManager.enabled: auto`). A site that already runs the platform's cert-manager keeps it.

What uses it, and what each one creates:

| User | Where | Objects |
|---|---|---|
| Grid enrollment (`apps/grid-bootstrap`) | hub | Issuer `redhat-ai-grid/grid-ca` (CA from `values/grid-bootstrap.yaml`: `Generate` or `Existing`) and each site's identity Certificate |
| Library Keycloak (`apps/keycloak`) | hub | Issuer `maas-db/keycloak-signing-selfsigned` and Certificate `keycloak-saas-signing` |
| OpenShift AI monitoring | sites | OpenTelemetry certificates; [OpenShift AI prerequisites](06-site-delivery.md#registry-access-and-openshift-ai-prerequisites) grants the OpenTelemetry operator access |
| MaaS gateway public certificate | ingress and combined sites | Yours: see [MaaS gateway certificate](../spokes/maas-certificate.md) |

The library uses only namespaced Issuers. A ClusterIssuer is yours to provide, and you need one only for the MaaS
gateway's public certificate.

#### Verify

```sh
oc get crd certificates.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io
oc -n cert-manager get pods
oc -n redhat-ai-grid get issuers.cert-manager.io grid-ca
oc -n redhat-ai-grid get certificates.cert-manager.io
```

You should see all three CRDs, the cert-manager pods `Running`, Issuer `grid-ca` `READY` `True`, and every
Certificate `READY` `True` once grid enrollment is installed. The hub prerequisites check reports `OK` for
`cert-manager CRDs`:

```sh
scripts/check-prerequisites.sh --step hub --context HUB_CONTEXT
```

Replace `HUB_CONTEXT` with your hub's kubeconfig context. Run it from a library checkout at your pinned commit.

### Bring your own

The verified install used the cert-manager Operator for Red Hat OpenShift that the platform had already installed on
the hub (v1.20.1) and on the combined site. The contract:

- The CRDs `certificates.cert-manager.io`, `issuers.cert-manager.io` and `clusterissuers.cert-manager.io` exist, and
  the controller reconciles Issuers and Certificates in every namespace.
- On each site, cert-manager runs in namespace `cert-manager` from the operator in `cert-manager-operator`, which is
  where the OpenShift AI chart and the OpenTelemetry grant expect it. A cert-manager installed another way (another
  namespace, an upstream Helm release) isn't covered. *(Unverified.)*
- For the MaaS gateway: a ClusterIssuer that can issue for your sites' apps domains with a DNS-01 solver
  ([MaaS gateway certificate](../spokes/maas-certificate.md)).

Leave `apps/cert-manager` out of your `files` list. Check with the verify commands and:

```sh
oc get clusterissuer
```

### Skip

You can't skip it. Without cert-manager on the hub, grid enrollment can't create the grid CA, so no site joins the
grid. Without it on a site, OpenShift AI doesn't install.

### Upgrade

The operator follows its Subscription (channel `stable-v1`, automatic approval), not the library pin. Moving the pin
changes only the Subscription manifest, if the library changes it.

### Known issues

None specific to cert-manager. The MaaS gateway's certificate issues are on the
[MaaS gateway certificate](../spokes/maas-certificate.md#known-issues) page, under Known issues.

## External Secrets Operator

The External Secrets Operator generates and copies Secrets on the hub, so no secret value is ever stored in git. Several
library components and the worked example's tenant IdP create their passwords and keys with its `Password` generators
and `ExternalSecret` resources.

| | |
|---|---|
| Runs on | hub (also the external-services cluster, when you use one) |
| Library component | `apps/external-secrets` (select `apps/external-secrets/application.yaml`) |
| Choices | Use ours · Bring your own · Skip (only if nothing in the table needs it) |

What uses it:

| Component | What it generates |
|---|---|
| [Object storage](01-acm.md#object-storage), S4 option (`apps/object-storage/s4`) | The S3 access and secret keys and `thanos.yaml` in Secret `open-cluster-management-observability/thanos-object-storage` |
| [Keycloak](04-tenant-identity.md#keycloak) (`apps/keycloak`), the library's tenant IdP | Keycloak's admin, client, broker, test-user and database passwords, and its keystore password, in namespace `maas-db` |
| [External services](../../../apps/external-services/README.md) | Installs this operator again on the cluster labelled `ai-grid/external-services=true` |
| Your own apps | The worked example's tenant IdP generates its client secret in a dedicated namespace and copies it to Keycloak's namespace with a `kubernetes` `SecretStore` |

Each generated value uses `refreshPolicy: CreatedOnce` and `deletionPolicy: Retain`: it's generated once, never
rotated, and kept if the `ExternalSecret` goes.

### Use ours

1. Select `apps/external-secrets/application.yaml` ([select it](#select-it)).

It reads only `libraryRepoURL` and `libraryRevision`, no file from your deployment repository, and no Secret you create.
It installs the Red Hat build of External Secrets Operator cluster-wide: namespace `external-secrets-operator`,
Subscription `openshift-external-secrets-operator` (channel `stable-v1`, catalog `redhat-operators`), and the
`ExternalSecretsConfig` `cluster`. Components that use it retry until its CRDs exist, so install order doesn't matter.

#### Verify

```sh
oc get subscription openshift-external-secrets-operator -n external-secrets-operator -o jsonpath='{.status.installedCSV}{"\n"}'
oc get crd externalsecrets.external-secrets.io passwords.generators.external-secrets.io
oc get externalsecrets -A
```

You should see an installed CSV, both CRDs, and every `ExternalSecret` with `READY` `True`.

### Bring your own

If your hub already runs an External Secrets Operator, it must serve these APIs, which the library's manifests use:

- `external-secrets.io/v1`: `ExternalSecret` (with `dataFrom.sourceRef.generatorRef`, `target.template` engine `v2`,
  `mergePolicy: Merge`) and `SecretStore`
- `generators.external-secrets.io/v1alpha1`: `Password`

Leave `apps/external-secrets/application.yaml` out of `files`, and check your operator serves them:

```sh
oc api-resources --api-group=external-secrets.io
oc api-resources --api-group=generators.external-secrets.io
```

You should see `externalsecrets` and `secretstores` in the first list and `passwords` in the second. A community
operator that serves the same API versions should work. *(Unverified.)*

### Skip

You can skip it only if you select neither the S4 object-storage option nor the library's Keycloak, and your own apps
don't use it. Otherwise their `ExternalSecret` resources never become Ready: S4 has no keys, so ACM observability
doesn't start, and the library's Keycloak has no admin or client secrets.

### Upgrade

The Subscription follows channel `stable-v1` with automatic approval, so updates within it install as they're
published. Because every generated value is `CreatedOnce`, an operator upgrade doesn't regenerate a password.

### Known issues

- **Symptom:** After you edit an `ExternalSecret`'s template, the Secret doesn't change.
  **Cause:** `refreshPolicy: CreatedOnce` writes the Secret once.
  **Workaround:** Delete the Secret so it's generated again, only when nothing depends on the old value. For the
  library Keycloak, see [`apps/keycloak/README.md`](../../../apps/keycloak/README.md), "Generated Secrets".

## Cluster sign-in and admins

Cluster administrators sign in to the hub and the sites through OpenShift's own identity providers, and the provider
console uses that same sign-in. The library's `cluster-config` component binds `cluster-admin` to the users you list on
every cluster; before you change any identity provider, you add a break-glass admin so you can't lock yourself out.

| | |
|---|---|
| Runs on | hub and every managed cluster |
| Library component | `cluster-config` (select `cluster-config/application.yaml`); the identity providers are infrastructure you provide |
| Choices | Use ours · Bring your own (your own RBAC) |

### Before you start: a break-glass admin

Add a local sign-in next to your cluster's existing identity providers before you install anything that could change
them, on the hub and on each site. If the identity provider you sign in with fails, this one still works. Never delete
an existing identity provider your platform uses.

The library's [`scripts/add-htpasswd-admin.sh`](../../../scripts/add-htpasswd-admin.sh) does this
([prepare the hub](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/03-prepare-hub.md#1-add-a-break-glass-admin)):

```sh
../library/scripts/add-htpasswd-admin.sh --kubeconfig KUBECONFIG --password-file PASSWORD_FILE
```

Replace the following:

- `KUBECONFIG`: a kubeconfig with a `cluster-admin` session on the cluster.
- `PASSWORD_FILE`: a path outside any git repository for the admin's password. If the file doesn't exist, the script
  generates a password into it (mode `600`) and never prints it.

The script creates Secret `openshift-config/htpasswd-htpasswd`, appends an `HTPasswd` identity provider named
`htpasswd` (`mappingMethod: add`) to OAuth `cluster` while keeping every existing provider, grants `cluster-admin` to
user `admin`, then waits until `admin` can sign in through the new provider. Use `--user` and `--idp` for other names.

### Use ours

1. Select `cluster-config/application.yaml` ([select it](#select-it)).

   It reads the `libraryRepoURL`, `libraryRevision`, `deploymentRepoURL` and `deploymentRevision` inputs.

2. Create `values/cluster-admins.yaml` in your deployment repository. It's required:

   ```yaml
   cluster_admins:
     - USERNAME
   ```

   Replace `USERNAME` with each OpenShift user name to bind, such as the break-glass `admin`. For no admins, write
   `cluster_admins: []`. Each name must be a valid DNS-1123 name (lowercase letters, digits, `-` and `.`), because it's
   part of the binding's name; a name such as `user@example.com` isn't supported yet.

3. Commit and push. No Secret is needed.

Argo CD creates ApplicationSet `cluster-config`, which generates one Application per cluster that ACM registered in
Argo CD (label `apps.open-cluster-management.io/acm-cluster=true`, written by `apps/argo-registration`), the hub
included. Each Application renders ClusterRoleBinding `cluster-admin-USERNAME` (`kind: User`) per listed user, and
prunes the binding of a user you remove. On the hub it also creates the `submariner-gateway-nodes` Policy, which labels
every worker-only node `submariner.io/gateway=true` on every cluster. The
[README](../../../cluster-config/README.md) has the details.

#### Verify

```sh
oc -n openshift-gitops get applications.argoproj.io \
  -l argocd.argoproj.io/application-set-name=cluster-config
oc get clusterrolebinding cluster-admin-USERNAME
oc --context SITE_CONTEXT get clusterrolebinding cluster-admin-USERNAME
```

Replace `USERNAME` with a listed user and `SITE_CONTEXT` with your kubeconfig context for a site.

You should see one `cluster-config-...` Application per cluster, `Synced` and `Healthy`, and the binding on the hub
and the site.

### Bring your own

If you manage cluster RBAC another way, you still select `cluster-config` for its Submariner gateway node Policy, and
give it `cluster_admins: []`. Your own contract for the admins:

- Each person who installs or operates AI Grid holds `cluster-admin` on the hub and on every site.
- The provider console signs users in with the hub's OpenShift OAuth, so a provider admin needs a hub user that your
  identity provider can sign in.

Check a user:

```sh
oc auth can-i '*' '*' --all-namespaces --as=USERNAME
```

You should see `yes`.

### Skip

You can't skip `cluster-config`: it also labels the Submariner gateway nodes, and Submariner needs at least two
worker-only nodes per cluster. An empty admin list is fine.

### Upgrade

`cluster-config` moves with the library pin with no manual step. The admin list moves with your deployment
repository: adding or removing a name takes effect on every cluster at the next sync.

### Known issues

- **Symptom:** Every cluster's `cluster-config-...` Application fails to sync with a missing values file.
  **Cause:** `values/cluster-admins.yaml` is missing or misnamed. The library fails on purpose instead of rendering no
  binding and pruning every admin.
  **Workaround:** Add the file, with `cluster_admins: []` for none.
- **Symptom:** You lose cluster access after an identity provider change.
  **Cause:** The provider you signed in with no longer works, and no other one does.
  **Workaround:** Sign in with the break-glass `htpasswd` admin, then repair the provider. Without one, recover with
  the installer's `kubeconfig`.

## Default StorageClass

The hub needs a default StorageClass: several components claim volumes without naming a class. The hub check reports it
as `default StorageClass` ([prepare the hub](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/03-prepare-hub.md#2-check-the-infrastructure)). If it's missing,
annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`.

| Claim | Size | Component |
|---|---|---|
| ACM observability's compactor, and other observability volumes | 101 GiB, and more | [ACM](01-acm.md#use-ours) |
| Each MaaS database instance (3 on the hub) | 20 GiB | [MaaS shared services](03-maas-shared-services.md#maas-database) |
| Each Redis instance (3 on the hub) | 10 GiB | [MaaS shared services](03-maas-shared-services.md#limitadors-redis) |
| S4, if you select it | 50 GiB | [Object storage](01-acm.md#object-storage) |
