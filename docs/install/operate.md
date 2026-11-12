# Operate

Day-2 tasks for an installed AI Grid. Run the commands from your deployment repository.

## Upgrade AI Grid

An upgrade is one commit to your deployment repository that moves the library pin.

1. Read the library's commits between your pin and the new one, for anything that needs a new input, values file or
   manual step.

2. Set every 40-character library commit in `root/kustomization.yaml` (the `bootstrap/hub` `?ref=`, the generator
   `revision` and `libraryRevision`) to `NEW_SHA`, then run
   [`scripts/sync-guide-pin.sh`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/scripts/sync-guide-pin.sh)
   to move the guide's links. The scripts fetch the library at the new pin into `.library/` the next time they need
   it. The commit carries both changes.

   ```sh
   sed -i.bak "s/OLD_SHA/NEW_SHA/g" root/kustomization.yaml && rm root/kustomization.yaml.bak
   scripts/check-deployment.sh
   scripts/sync-guide-pin.sh
   git commit -am "root: move the library pin to NEW_SHA_SHORT" && git push
   ```

3. Wait for Argo CD. `deployment-root` applies the new root, and every component follows, including the Applications
   that nested ApplicationSets generate on the sites.

   From your deployment repository, run [`scripts/check-revisions.sh`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/scripts/check-revisions.sh). It runs the library's
   `scripts/check-revisions.sh` at your pin against the hub:

   ```sh
   scripts/check-revisions.sh
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
3. To reuse the cluster with another hub, [clean it](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/05-prepare-site.md#reuse-a-cluster-from-another-hub),
   or uninstall it with `scripts/uninstall.sh site NAME` in your deployment repository ([uninstall AI Grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/08-uninstall.md#3-uninstall-each-site)).

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

To remove AI Grid from your clusters, see [Uninstall AI Grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/08-uninstall.md) in your deployment repository.
