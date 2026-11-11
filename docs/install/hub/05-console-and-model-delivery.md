# Provider console and model delivery

The provider console is the cloud provider's admin UI on the hub: it adds clusters to the grid, creates organizations
in Keycloak, and commits models and subscriptions to your catalog repository. Model delivery takes the catalog to the
sites by role.

| | |
|---|---|
| Options | The console is optional. Model delivery is required to serve models. |
| Example chose | Both; no sample models |
| Requires | Console: a Keycloak tenant IdP with Organizations ([tenant identity](04-tenant-identity.md)), and a token that can write only the catalog repository. Model delivery: a catalog repository ([create your repositories](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/02-repositories.md)) and [site delivery](06-site-delivery.md). |

## Select it

```yaml
- path: apps/acm-models/application.yaml
- path: apps/console/application.yaml
```

Leave out `apps/console` with an IdP that isn't Keycloak ([skip the console](#skip)). For a demo only, add
`- path: apps/acm-models-samples/application.yaml` ([sample models](#sample-models-demo-only)).

## Provider console

This component runs the cloud provider's admin console and its backend on the hub, in one pod with an OpenShift
sign-in proxy. Provider admins use it to add clusters to the grid, create organizations in Keycloak, and deploy models
and subscriptions as commits to the catalog repository, which [model delivery](#model-delivery) delivers and
[AI Grid Policies](02-grid.md#ai-grid-policies) report on.

| | |
|---|---|
| Runs on | hub |
| Library component | `apps/console` (select `apps/console/application.yaml`) |
| Choices | Use ours. Bring your own isn't an option. Skip: yes, see [Skip](#skip). |
| Requires | `apps/acm-models`; a **Keycloak** tenant IdP with Organizations. With any other OIDC provider, skip the console. |

### Use ours

1. Select `apps/console/application.yaml` ([select it](#select-it)).

   It reads the inputs `catalogRepoURL`, `catalogRevision`, `libraryRepoURL` and `libraryRevision`. It installs the
   console's Helm chart from `ai-grid-cloud/ai-grid-provider-console` at a pinned commit, with images by digest, into
   namespace `ai-grid-provider-console`, and binds the backend to ACM Search and to Policy
   `ai-grid-policies/ai-grid-ready`.

2. Create a fine-grained GitHub token with **Contents: Read and write** on the catalog repository only, and save it
   to a file outside any repository. Whoever holds this token can change every site's models and subscriptions. Never
   give it access to your deployment repository or the library: Argo CD applies those with cluster-admin rights.

3. Wait until Argo CD has created the console's Route:

   ```sh
   oc -n ai-grid-provider-console get route ai-grid-provider-console
   ```

4. As a hub cluster-admin, from a checkout of the library at your pinned commit, create the console's Secrets:

   ```sh
   AI_GRID_GIT_TOKEN_FILE=TOKEN_FILE \
   KEYCLOAK_NAMESPACE=KEYCLOAK_NAMESPACE KEYCLOAK_REALM=KEYCLOAK_REALM \
     bash apps/console/create-secrets.sh
   ```

   Replace the following:

   - `TOKEN_FILE`: the path to the token file from step 2. Required.
   - `KEYCLOAK_NAMESPACE`: the hub namespace that holds your Keycloak's Route `keycloak` and Secret `keycloak-secrets`.
     Defaults to `maas-db`, where the library's Keycloak runs.
   - `KEYCLOAK_REALM`: the realm whose organizations the console manages. Defaults to `saas`, the library's realm.

   Other optional variables: `HUB_CONTEXT` (kubeconfig context), `NAMESPACE` (defaults to
   `ai-grid-provider-console`), `KEYCLOAK_BACKEND_USER` (defaults to `ai-grid-console-backend`),
   `KEYCLOAK_BACKEND_URL` (defaults to Keycloak's public Route), `ADOPT_KEYCLOAK_USER_ID`, and `CURL_CA_BUNDLE` for
   a Keycloak Route behind a private CA. The script prints no secret value and is safe to rerun.

   The script creates or updates, in `ai-grid-provider-console`:

   - OAuthClient `ai-grid-provider-console` and Secret `ai-grid-provider-console-oauth`: OpenShift sign-in.
   - Secret `ai-grid-backend-keycloak`: the backend's Keycloak URL, realm, user and password. The script creates that
     Keycloak user in the realm with only the realm-management roles it needs, signing in with the admin login in
     `KEYCLOAK_NAMESPACE/keycloak-secrets`.
   - Secret `ai-grid-backend-git`: the catalog token.

   Then it restarts the console. The [README](../../../apps/console/README.md) explains the Keycloak user and the
   private-CA options.

5. Sign in at the Route's URL with an OpenShift user that may patch ManagedClusters, such as a cluster-admin. Provider
   admins sign in with OpenShift users, not with tenant IdP accounts.

#### Verify

On the hub:

```sh
oc -n ai-grid-provider-console get pods
oc -n ai-grid-provider-console get route ai-grid-provider-console -o jsonpath='{.spec.host}{"\n"}'
oc -n ai-grid-provider-console get secrets \
  ai-grid-provider-console-oauth ai-grid-backend-keycloak ai-grid-backend-git
```

You should see one pod `3/3 Running` (sign-in proxy, console and backend), the console's host name, and the three
Secrets. Open `https://HOST` and sign in; the **Clusters** page lists your ManagedClusters, each site Provisioning or
Provisioned.

### Bring your own

Not an option: the library has no contract for another console. The console works only with Keycloak: it creates
organizations through Keycloak's admin API. With a tenant IdP that isn't Keycloak, skip the console. You choose which
Keycloak: the console works with any Keycloak that has a Route named `keycloak` and a Secret `keycloak-secrets` with keys `KC_BOOTSTRAP_ADMIN_USERNAME`
and `KC_BOOTSTRAP_ADMIN_PASSWORD` in one namespace, and a realm for organizations; point `KEYCLOAK_NAMESPACE` and
`KEYCLOAK_REALM` at them. The example deployment uses its own community Keycloak 26.8.0 in namespace `tenant-idp`, realm
`tenants`.

### Skip

You can skip it. Without it you add sites by labelling ManagedClusters by hand, manage organizations in Keycloak
directly, and commit models and subscriptions to the catalog yourself ([model delivery](#model-delivery)). You can
then also skip [AI Grid Policies](02-grid.md#ai-grid-policies). *(Unverified.)*

### Upgrade

The chart commit and both image digests are pinned in the library, so they move with the library pin, and the console
and backend always move together. Rerun `create-secrets.sh` after you change the Keycloak URL or rotate the catalog token, or when the console's
README at the new pin asks for it, such as after a change to the backend's Keycloak roles.

### Known issues

**Symptom:** creating an organization in the console fails with Bad Request.
**Cause:** the backend sends `autoRedirect` in organization domains, which Red Hat build of Keycloak 26.4 and 26.6
reject.
**Workaround:** run community Keycloak 26.8.0 for the realm the console manages, as the library's Keycloak and the
example deployment do.

**Symptom:** the script stops on a rerun and prints a Keycloak user ID.
**Cause:** a backend user exists that no Secret records, such as one an older script version created.
**Workaround:** check that the user is the console's, then rerun with `ADOPT_KEYCLOAK_USER_ID=USER_ID`.

**Symptom:** the console can't reach Keycloak on a cluster whose ingress certificate a private CA signs.
**Cause:** the backend image trusts only the system roots, and the chart has no setting for another CA.
**Workaround:** rerun the script with `KEYCLOAK_BACKEND_URL` set to Keycloak's in-cluster Service URL, such as
`http://keycloak.KEYCLOAK_NAMESPACE.svc:8080`, and `CURL_CA_BUNDLE` set to the ingress CA file. *(Unverified.)*

## Model delivery

`apps/acm-models` delivers the catalog, the models and subscriptions the [provider console](#provider-console) commits to
your catalog repository, to the sites by role. `apps/acm-models-samples` adds the library's sample model for a demo.
The console's model and subscription pages depend on `apps/acm-models`; [AI Grid Policies](02-grid.md#ai-grid-policies)
report what it delivered.

| | |
|---|---|
| Runs on | hub (ApplicationSets); models on inference and combined sites, MaaS objects on ingress and combined sites |
| Library component | `apps/acm-models` (select `apps/acm-models/application.yaml`); optional `apps/acm-models-samples` (select `apps/acm-models-samples/application.yaml`) |
| Choices | Use ours. Bring your own: a catalog you write yourself. Skip: samples only. |

### Use ours

1. Create the catalog repository: an empty git repository, such as a new GitHub repository with only a README. Only
   the console's git writer commits to it. Keep it apart from your deployment repository, because whoever holds the
   writer's token can change it.

2. Set the inputs `catalogRepoURL` (the repository's URL) and `catalogRevision` (a branch, such as `main`, because the
   console pushes to it) in your root's `values`.

3. Select `apps/acm-models/application.yaml` ([select it](#select-it)).

   It also needs [spoke delivery](06-site-delivery.md#spoke-delivery) for its Placements and Argo CD cluster registration.

Argo CD creates, in `openshift-gitops` on the hub, two AppProjects and three ApplicationSets:

| Catalog path | ApplicationSet | Delivers to | Namespace |
|---|---|---|---|
| `catalog/clusters/SITE/` | `acm-models-catalog-models` | that `inference` or `combined` site, once the folder exists | `ai-grid-internal-models` |
| `catalog/ingress/` | `acm-models-catalog-ingress` | every `ingress` or `combined` site | `models-as-a-service` |
| `catalog/subscriptions/` | `acm-models-catalog-subscriptions` | every `ingress` or `combined` site | `models-as-a-service` |

The git writer lays the catalog out this way:

- `catalog/models/MODEL/deployment/`: the LLMInferenceService and its NetworkPolicy.
- `catalog/models/MODEL/catalog/model.yaml`: the model's ExternalModel and MaaSModelRef.
- `catalog/clusters/SITE/kustomization.yaml`: the models placed on that site, as `../../models/MODEL/deployment`.
- `catalog/ingress/kustomization.yaml`: every model's `../models/MODEL/catalog`.
- `catalog/subscriptions/SUBSCRIPTION.yaml`: a MaaSSubscription and its MaaSAuthPolicy `SUBSCRIPTION-policy`.

The catalog's Applications run in AppProjects `acm-models-catalog-models` (LLMInferenceService, NetworkPolicy) and
`acm-models-catalog-maas` (ExternalModel, MaaSModelRef, MaaSSubscription, MaaSAuthPolicy), which admit only the
catalog repository, no cluster-scoped kinds and only those kinds. An empty catalog generates no Applications and shows
no errors.

Deleting a site's folder or the models ApplicationSet leaves its models running. Deleting an ingress or subscriptions
Application deletes its MaaS objects with it, so no tenant access outlives it. The
[README](../../../apps/acm-models/README.md) covers deletion and metrics in depth.

#### Verify

After the console's first model and subscription ([First use](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/08-first-use.md)), on the hub:

```sh
oc -n openshift-gitops get applicationsets.argoproj.io | grep acm-models-catalog
oc -n openshift-gitops get applications.argoproj.io | grep acm-models-catalog
```

You should see the three ApplicationSets, and Applications `acm-models-catalog-models-SITE`,
`acm-models-catalog-ingress-SITE` and `acm-models-catalog-subscriptions-SITE` `Synced` and `Healthy`. On the site:

```sh
oc -n ai-grid-internal-models get llminferenceservices
oc -n models-as-a-service get externalmodels,maasmodelrefs,maassubscriptions,maasauthpolicies
```

You should see the model `READY` `True` and the MaaS objects `Ready` or `Active`, about 2 minutes after the
Applications appear.

#### Sample models (demo only)

`apps/acm-models-samples` delivers `facebook-opt-125m` on CPU to inference and combined sites, its ExternalModel and
MaaSModelRef to ingress and combined sites, and sample subscriptions for organizations that exist only in the library's
own lab. The root drops its second sample (`smollm2-135m-instruct`). Skip it in production: models and subscriptions
belong in the catalog. If you select it for a demo, add `- path: apps/acm-models-samples/application.yaml`.
*(Unverified.)*

### Bring your own

You can write the catalog yourself instead of through the console: commit files in the layout that [Use ours](#use-ours-1) describes to
the repository `catalogRepoURL` names. The AppProjects reject any other kind or namespace. A file that collides with
an object another Application manages stops that site's catalog sync (`FailOnSharedResource`). *(Unverified.)*

### Skip

You can skip `apps/acm-models-samples`. You can't skip `apps/acm-models` if you want to serve models: nothing else
delivers the catalog, and the console's writes would reach no site.

### Upgrade

Both components move with the library pin and need no manual step. Models and subscriptions move only when the catalog
changes.

### Known issues

**Symptom:** after the console's first commits, no `acm-models-catalog-*-SITE` Application appears.
**Cause:** the ApplicationSets' git generator kept its cached view of the empty catalog.
**Workaround:** refresh each catalog ApplicationSet once on the hub. *(Unverified.)*

```sh
for a in models ingress subscriptions; do
  oc -n openshift-gitops annotate applicationsets.argoproj.io acm-models-catalog-$a \
    argocd.argoproj.io/application-set-refresh=true --overwrite
done
```

**Symptom:** `facebook-opt-125m` (OPT-125m) is listed in `/v1/models`, but chat calls through MaaS return 400.
**Cause:** OPT-125m has no chat template, and the MaaS gateway sends completions to the chat endpoint.
**Workaround:** deploy a chat model, such as SmolLM2-135M-Instruct, for tests.

**Symptom:** a teardown leaves a model running with no MaaS entry.
**Cause:** model Applications preserve their resources; MaaS Applications delete theirs.
**Workaround:** on the site, delete the model by hand:
`oc -n ai-grid-internal-models delete llminferenceservice MODEL`.
