# Operate

Day-2 tasks for an installed AI Grid. Run the commands from your deployment repository, with the library checked
out at `../library` as in the install guide.

## Upgrade AI Grid

An upgrade is one commit to your deployment repository that moves the library pin.

1. Read the library's commits between your pin and the new one, for anything that needs a new input, values file or
   manual step.

2. In `root/kustomization.yaml`, replace the old SHA with the new one in all three places: the remote base
   (`?ref=`), the generator `revision`, and `values.libraryRevision`. `sync-guide-pin.sh` then moves the install guide's
   links into the library to the new SHA, and the commit carries both.

   ```sh
   sed -i.bak "s/OLD_SHA/NEW_SHA/g" root/kustomization.yaml && rm root/kustomization.yaml.bak
   git -C ../library fetch -q && git -C ../library checkout -q NEW_SHA
   ../library/scripts/check-deployment.sh .
   scripts/sync-guide-pin.sh
   git commit -am "root: move the library pin to NEW_SHA_SHORT" && git push
   ```

3. Wait for Argo CD. `deployment-root` applies the new root, and every component follows, including the Applications
   that nested ApplicationSets generate on the sites.

   ```sh
   ../library/scripts/check-revisions.sh --deployment . --kubeconfig HUB_KUBECONFIG
   ```

   You should see `N library sources checked, 0 not at NEW_SHA7`. Any `OFF` line names an Application that still
   reads another commit. On the tested hub, 28 library sources moved in about 6 minutes.

4. Rerun the checks from [join the site to the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md#3-verify) and a tenant call from [first use](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/07-first-use.md#6-call-the-model-as-a-tenant).

Before a pin that changes the Keycloak version, read
[Keycloak](hub/04-tenant-identity.md#known-issues-1): Keycloak's import-then-start layout can't migrate
an older database.

## Add a site

Follow [prepare the site](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/05-prepare-site.md) and [join the site to the grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md) for the new site.

- For an `ingress` or `inference` site instead of `combined`, see
  [Sites](spokes/README.md#what-you-choose-per-site). An `inference` site needs no files from
  `site-template/`; label it with `ai-grid/role=inference`.
- With more than one site, give the hub's Argo CD application controller 8 GiB of memory
  ([OpenShift GitOps](hub/00-platform-services.md#openshift-gitops)).
- Add each ingress or combined site's `https://maas.SITE_APPS_DOMAIN/*` to the tenant Keycloak's redirect URIs, in its
  admin console ([tenant-idp/README.md](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/tenant-idp/README.md#settings)).

## Remove a site

1. Remove the AI Grid label: `oc label managedcluster SITE ai-grid/enabled-`. Within about 30 seconds the hub
   removes the site's `rhoai`, catalog and policy Applications, and the site's MaaSSubscriptions and MaaSModelRefs; the
   `maas-db` replica goes about 3 minutes later. OpenShift AI and the model servers stay installed, no longer managed,
   and the console shows the site as **Not added**. The site **stays in the grid**: its GridSite remains `Connected`
   and `Available`, and withdrawing it isn't designed yet ([known gaps](known-gaps.md)). Submariner's
   Application stays until the ManagedCluster goes.

   To add the site back, label it again: on the tested hub all 29 Applications were Synced and Healthy 5½ minutes
   later, with the site's models and subscriptions as before.
2. To remove it from ACM too, delete the ManagedCluster, then any Argo CD cluster Secret and grid identity Secret
   (`redhat-ai-grid/grid-site-SITE`) left on the hub.
3. To reuse the cluster with another hub, [clean it](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/05-prepare-site.md#reuse-a-cluster-from-another-hub).

## Remove a subscription, model or organization

In the console, open the row's menu in each list and click **Delete**, then type the name to confirm. Delete in this
order:

1. The subscription. Its authorization policy is deleted with it.
2. The model. It's removed from every site it runs on.
3. The organization, with its identity provider configuration.

Each delete of a subscription or model is a commit to your catalog repository; the organization lives in Keycloak.
On the site, a model takes about 9 minutes to go: its ExternalModel keeps its finalizer until the model's pods end.

## Rotate credentials

| Credential | How | Verified |
|---|---|---|
| Catalog token | Rerun `apps/console/create-secrets.sh` with the new token file ([provider console](hub/05-console-and-model-delivery.md#provider-console)). | No |
| Tenant IdP client secret | Change it in the IdP, then update the hub Secret your `idpClientSecret*` inputs name; the tenant Policy copies it to the sites. | No |
| `quay.io/rhoai` pull secret | Rerun `apps/rhoai-prerequisites/create-hub-secret.sh` ([OpenShift AI prerequisites](hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). | No |

## Uninstall

The uninstall returns each cluster to how it was before you [prepared the hub](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/03-prepare-hub.md): OpenShift with your platform's
own services, plus the break-glass admin. It removes everything the install put there, sites first, then the hub.

### What "before" means

| Cluster | After the uninstall | Removed |
|---|---|---|
| Hub | OpenShift; the platform's identity provider, cert-manager and certificate issuers; the htpasswd admin | OpenShift GitOps, ACM and the multicluster engine, every component and your own apps, their operators and namespaces |
| Site | OpenShift; the platform's identity provider, cert-manager, NFD and GPU operator; the htpasswd admin | OpenShift AI, MaaS, the grid, Submariner, the ACM agent, everything the hub's Applications applied, their operators and namespaces |

Left on purpose, on every cluster:

- **CustomResourceDefinitions.** A reinstall reuses them; deleting a CRD deletes every object of its kind, including
  ones your platform owns.
- **The cluster pull secret's `quay.io/rhoai` and stage entries, and the image mirror.** A reinstall delivers the same
  again, and removing a mirror drains every node. Remove them by hand if you won't reinstall.
- **The protected namespaces and operators:** `keycloak`, `cert-manager`, `cert-manager-operator`,
  `openshift-cert-manager-operator`, `openshift-nfd`, `nvidia-gpu-operator`, `openshift-config`,
  `openshift-authentication`, and the packages `rhbk-operator`, `openshift-cert-manager-operator`, `nfd`,
  `gpu-operator-certified`. Add your platform's own with `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES`
  (space-separated). ClusterIssuers and the OAuth configuration are never touched.
- **Your deployment and catalog repositories,** except that you empty the catalog (part 1).

The uninstall reads what to delete from Argo CD's own record of what it applied (each Application's
`status.resources`), so your own apps in `apps/*.yaml` go too. Operators then remove what they created, because their
custom resources are deleted while they still run. What operators and add-ons leave outside that record and outside
the namespaces the uninstall deletes (in `openshift-ingress`, `openshift-monitoring`, `kube-system` and cluster-wide:
RBAC, console entries, ACM's cluster claims and image sets) is listed in `scripts/uninstall-leftovers.tsv`, which each
step deletes last. Add your own lines there if your apps leave something behind.

### 1. Empty the catalog

So a reinstall starts with no models or subscriptions, remove them from your catalog repository. With the console,
delete each subscription, then each model ([remove a subscription, model or organization](#remove-a-subscription-model-or-organization)).
Or in git:

```sh
git clone CATALOG_REPO_URL catalog && cd catalog
git rm -r -q -- $(git ls-files | grep -vx README.md)
git commit -m "catalog: empty for uninstall" && git push origin HEAD:main && cd ..
```

Within a few minutes the hub deletes the catalog's Applications, and with them the subscriptions, auth policies and
MaaS model entries, so no access outlives them. The models themselves keep running: the models ApplicationSet keeps
its resources when a cluster's folder goes (`preserveResourcesOnDeletion`, see `apps/acm-models/README.md`). The
site step deletes them first, while KServe still runs.

### 2. Preview each step

Each step needs the hub's and the site's kubeconfig, their API URLs, and the break-glass admin's password file. The
script refuses a cluster whose API URL doesn't match, and refuses unless the admin signs in with the password and keeps
`cluster-admin` through a binding the uninstall doesn't delete.

```sh
../library/scripts/uninstall.sh --step site --dry-run \
  --hub-kubeconfig HUB_KUBECONFIG --expect-hub-api HUB_API_URL \
  --site SITE --site-kubeconfig SITE_KUBECONFIG --expect-site-api SITE_API_URL \
  --admin-password-file ADMIN_PASSWORD_FILE
```

Replace the following:

- `HUB_KUBECONFIG`, `SITE_KUBECONFIG`: kubeconfig files with a `cluster-admin` session on each cluster.
- `HUB_API_URL`, `SITE_API_URL`: each cluster's API URL, as `oc whoami --show-server` prints it.
- `SITE`: the site's ManagedCluster name.
- `ADMIN_PASSWORD_FILE`: the break-glass admin's password file ([prepare the hub](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/03-prepare-hub.md#1-add-a-break-glass-admin)).
  Use `--admin-user` if the user isn't `admin`, and `--site-admin-password-file` if the site's admin password differs
  from the hub's.

The output lists every step and every object it would delete, in order, and the objects it keeps because they're
protected. Read it: nothing protected may be in the delete list. Preview the hub the same way with `--step hub` and
only the hub's flags; until every site is uninstalled, its preview warns that sites are still managed.

### 3. Uninstall each site

Run the site command without `--dry-run`, for each site, and add `--plan-file SITE-uninstall-plan.tsv`. The plan
comes from the site's Applications on the hub, which the first steps remove; if the run stops partway, run the same
command again with the same plan file to resume. It:

1. Removes the site's `ai-grid/enabled` and `ai-grid/role` labels and waits for its Applications to go.
2. Detaches the site from ACM, deletes the Argo CD cluster Secret and grid identity the detach leaves on the hub, and
   waits for ACM to remove the site's agent.
3. Deletes from the site, in order: models while KServe runs; MaaS objects, including `MaaSTenantConfig` and
   `AITenant`, before the DataScienceCluster; the DataScienceCluster and its components; the grid's `GridNetwork` and
   `GridSite`; the AI Grid gateways and their EnvoyFilters; the operators; their leftover webhooks; their namespaces.
4. Deletes everything else the hub's Applications had applied to the site.
5. Deletes the ACM `Klusterlet`, then the namespaces that Argo CD's inventory doesn't list: the ACM agent's and
   policy namespaces, the site's own policy namespace, Submariner's, and the operator-created `ai-tenants` and
   `redhat-ai-gateway-infra`, each only if it's still there.
6. Signs in as the break-glass admin again.

A site takes about 15 minutes, most of it removing the DataScienceCluster and the operators.

### 4. Uninstall the hub

```sh
../library/scripts/uninstall.sh --step hub --plan-file hub-uninstall-plan.tsv \
  --hub-kubeconfig HUB_KUBECONFIG --expect-hub-api HUB_API_URL --admin-password-file ADMIN_PASSWORD_FILE
```

As with a site, if the run stops partway, run the same command again with the same plan file.

It refuses while any site is still managed. It:

1. Stops Argo CD: deletes the ApplicationSets without cascading, then removes each Application's finalizer and
   deletes it. Deleting the root alone would delete nothing, because the root keeps resources when it's removed.
2. Deletes, in order: the hub's ACM Policies and Placements; custom resources while their operators run (databases,
   ExternalSecrets, S4); MultiClusterObservability, then MultiClusterHub, then the multicluster engine; other objects;
   cluster-scoped objects; operator subscriptions with their CSVs; namespaces.
3. Deletes ACM's documented leftovers (admission APIServices and webhooks), then the namespaces that ACM's add-ons,
   the multicluster engine and the operators leave outside Argo CD's inventory, such as `default-broker`,
   `submariner-operator`, `external-secrets`, `hive` and `local-cluster`, each only if it's still there.
4. Deletes OpenShift GitOps last: it first tells the operator to stop recreating its default Argo CD instance
   (`DISABLE_DEFAULT_ARGOCD_INSTANCE`), so the operator removes the instance itself.
5. Deletes webhook configurations whose services all lived in namespaces the uninstall deleted. They'd reject a
   reinstall's writes.
6. Signs in as the break-glass admin again.

A hub takes about 25 minutes, most of it removing MultiClusterHub, the multicluster engine and OpenShift GitOps.

### 5. Check

On each cluster:

```sh
oc get applications.argoproj.io -A 2>&1 | head -1
oc get ns | grep -E 'open-cluster-management|multicluster-engine|redhat-ods|redhat-ai-grid|maas|ai-grid|gitops|kuadrant'
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}{"\n"}'
```

You should see that the Argo CD Application kind doesn't exist (`the server doesn't have a resource type`), no
namespace from the list, and your platform's identity providers plus `htpasswd`. Sign in once in the web console as the
break-glass admin.

To reinstall, start again at [set up your deployment repository](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/02-repositories.md) with the same or new
repositories.
