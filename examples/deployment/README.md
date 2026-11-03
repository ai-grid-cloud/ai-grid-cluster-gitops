# Example deployment repository

A deployment repository holds what belongs to one deployment of this template:
its clusters' values, its admins and the apps only it runs. The hub bootstraps
from this template unchanged and reads the deployment repository as well, so a
deployment needs no fork. This directory is an example of one, for a hub
bootstrapped with the dedicated-hub profile.

To use it, copy this directory into a repository of your own, change the
example values, and bootstrap the hub with it
([hub onboarding](../../docs/acm/hub-onboarding/README.md#using-a-deployment-repository)):

```bash
export DEPLOYMENT_REPO_URL=https://github.com/<org>/<deployment>.git
export DEPLOYMENT_REVISION=main         # default HEAD
export DEPLOYMENT_PATH=deployment       # the directory that holds these files
BOOTSTRAP_PROFILE=dedicated-hub ./bootstrap.sh
```

Every file is optional. A deployment repository with none of them deploys
exactly what the template deploys.

## Layout

Paths are relative to `DEPLOYMENT_PATH`. `<cluster>` is the ACM ManagedCluster
name (`local-cluster` for the hub).

| Path | Read by | Effect |
|---|---|---|
| `clusters/<cluster>/rhoai.yaml` | The `rhoai` ApplicationSet | Helm values for that cluster's `rhai-on-openshift` release, after the template's `apps/rhoai/values.yaml`, `apps/rhoai/roles/<role>.yaml` and `apps/rhoai/values-<cluster>.yaml`. |
| `clusters/<cluster>/maas-sites.yaml` | The `rhoai` ApplicationSet | Helm values for that cluster's `maas-sites` release, after the template's `apps/rhoai/maas-sites/values-<cluster>.yaml`. |
| `cluster-admins.yaml` | The `cluster-config` ApplicationSet | `cluster_admins` replaces the template's list in `cluster-config/values.yaml`. `cluster_admins: []` grants no one. |
| `apps/<name>.yaml` | The root ApplicationSet | One Argo CD Application each (format below). |
| Anything else | Your apps | Manifests your apps name, such as `catalog/`, `gpu/` and `keycloak-settings/` here. Keep them outside `apps/`: the root ApplicationSet's glob can match files in subdirectories of `apps/`. |

## Apps

An app file has the format of the template's `apps/*/application.yaml`: an
Argo CD Application with `metadata.name`, `metadata.namespace`, `spec.project`,
`spec.destination.server` and `spec.destination.namespace`, all required.
The root ApplicationSet replaces these tokens anywhere in its `spec`:

| Token | Value |
|---|---|
| `@deploymentRepoURL@` | `DEPLOYMENT_REPO_URL` |
| `@deploymentRevision@` | `DEPLOYMENT_REVISION` |
| `@deploymentPath@` | `DEPLOYMENT_PATH` |
| `@templateRepoURL@` | The template repository the hub bootstrapped from |
| `@templateRevision@` | The revision the template's own apps follow (`HEAD`, or the one `scripts/set-tenant-repo.sh` set) |

Tokens in files that an app reads, such as a kustomization or a nested
ApplicationSet, aren't replaced. To hand the values to a nested ApplicationSet,
patch its generator's `values` from the app, as `apps/gpu.yaml` does.

Give each app a name the template doesn't use. Argo CD keeps the template's
Application and reports the deployment's as a duplicate, and the
dedicated-hub profile changes the apps named `acm`, `acm-models`,
`grid-bootstrap`, `limitador-redis` and `rhoai`.

The example apps:

| App | What it runs | Before you use it |
|---|---|---|
| `catalog.yaml` | The provider console's catalog ApplicationSets and AppProjects (`catalog/kustomization.yaml`), pointed at your catalog repository. | Replace `example-org/example-catalog` with your catalog repository, and pin the template URLs' `main` to the commit the hub runs. Use it only with the dedicated-hub profile; the default profile's `acm-models` app already delivers these objects. |
| `console.yaml` | The provider console, from its Helm chart, with OpenShift sign-in, Perses project `redhat-ods-monitoring` and models in `ai-grid-internal-models`. | Set `backend.git.url` to your catalog repository, then run the template's `apps/console/create-secrets.sh` ([apps/console](../../apps/console/README.md)). Dedicated-hub profile only; the default profile runs its own console app. |
| `gpu.yaml` | Node Feature Discovery and the NVIDIA GPU operator on each inference and combined spoke (`gpu/`). | Nothing; on a spoke without an NVIDIA GPU the operator runs no driver pods. |
| `keycloak-settings.yaml` | ConfigMap `keycloak-realm-import-settings` (`keycloak-settings/`) in Keycloak's namespace on the hub: Keycloak imports only missing realms, so organizations the console creates survive a restart. | Nothing for the dedicated-hub profile's hub Keycloak. |
| `cluster-config.yaml` | The template's `cluster-config` on a dedicated hub: `cluster-admins.yaml`'s users, and the Submariner gateway-node Policy. | Edit `cluster-admins.yaml`. Dedicated-hub profile only. |

## Keep the catalog in another repository

The provider console pushes models and subscriptions to its catalog
repository with a token. Argo CD applies this repository with cluster-admin
rights on the hub, so anyone who can push here is cluster-admin on every
cluster. Keep the catalog in a separate repository that the console's token
can write and that holds nothing else, and protect this repository's branch
like the template's.
