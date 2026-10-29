# Deployment values

Everything in this repository outside `deployment/` is the same for every
deployment. This directory holds what belongs to one deployment: cluster
names, hostnames, peers and admins. It's the reference deployment's own
values (hub `local-cluster`, spoke `ai-grid-2`).

Another deployment keeps the same layout in its own repository and points the
template at it when it bootstraps:

```sh
export DEPLOYMENT_REPO_URL=https://github.com/example/my-deployment.git
export DEPLOYMENT_REVISION=main     # default HEAD
export DEPLOYMENT_PATH=deployment   # default deployment
./bootstrap.sh
```

`bootstrap.sh` fills these into the root ApplicationSet, which replaces the
tokens `@deploymentRepoURL@`, `@deploymentRevision@` and `@deploymentPath@` in
each `application.yaml`, and reads the deployment's optional apps from
`apps/*.yaml`. The `rhoai` ApplicationSet receives them as cluster
generator values (`apps/rhoai/application.yaml`). With none set, a deployment
reads this directory, so this repository deploys exactly as before.

## Layout

| Path | Used by | Required |
|---|---|---|
| `rhoai.yaml` | The `rhai-on-openshift` release on every cluster, after `apps/rhoai/values.yaml`. | No |
| `clusters/<cluster>/rhoai.yaml` | The same release on one cluster: its consumer backends. | No |
| `clusters/<cluster>/provider-gateway.yaml` | The cluster's grid provider gateway: Route host, model backends. Its presence installs the gateway (`apps/rhoai/hub/04-provider-gateway-applicationset.yaml`). | No |
| `hub/` | Objects applied to the hub only, such as declared peers. The directory must exist. | Yes |
| `apps/<name>.yaml` | One Argo CD Application per optional app the deployment runs: `keycloak`, `maas-db`, `limitador-redis`, `acm-models` (the provider console's catalog, below) and `acm-models-samples` (the sample models). Same format as `apps/*/application.yaml`; `@templateRepoURL@` names this repository. | No: an app not listed doesn't run |
| `keycloak/` | A kustomize overlay of `apps/keycloak`: the realms (`keycloak-realm-import`) and the generated secrets their placeholders need. Keycloak's public URL isn't a value: it's the Route's assigned host (`apps/keycloak/README.md`). Another repository names the base remotely, `https://github.com/kahowell/ai-grid-tenant//apps/keycloak?ref=cloud-provider`. | With `apps/keycloak.yaml` |
| `cluster-admins.yaml` | `cluster-config`: users granted `cluster-admin`. `cluster_admins: []` grants no one. | Yes |

`<cluster>` is the ACM ManagedCluster name (`local-cluster` for the hub).

## A catalog a provider console writes

`apps/acm-models/hub` holds the provider console's catalog: ApplicationSets
that deploy the models and subscriptions its git writer commits to a catalog
repository, the status Policies it reads back, and `ai-grid-ready`. List it in
`<deployment>/apps/acm-models.yaml` (this deployment's is the example) and name
the repository when you bootstrap (`CATALOG_REPO_URL`, `CATALOG_REVISION`; no
default). The app's kustomize patches put that repository in place of the
reference's.

| Catalog path | Delivered to | Namespace |
|---|---|---|
| `catalog/clusters/<cluster>/` | That cluster, if it's an inference or combined spoke | `ai-grid-internal-models` |
| `catalog/ingress/` | Every ingress and combined spoke | `models-as-a-service` |
| `catalog/subscriptions/` | Every ingress and combined spoke | `models-as-a-service` |

The catalog's apps run in two AppProjects that admit only the catalog
repository and only the kinds the console writes; the grid's InferenceProvider
is the one cluster-scoped kind (`apps/acm-models/README.md`). A
catalog file that collides with an object another Application manages stops
that cluster's catalog sync until it's fixed.

Keep the catalog in a different repository from these deployment values: the
git writer pushes to the catalog, and anyone who can push here is
cluster-admin. `bootstrap.sh` refuses the same repository unless
`CATALOG_IN_DEPLOYMENT_REPO=yes` accepts that risk, for clusters you can
rebuild.

The sample models in the same directory are a separate app,
`<deployment>/apps/acm-models-samples.yaml`: they bring a subscription for
this deployment's own organization, so another deployment leaves them out.

## Who can change a cluster through this repository

Argo CD applies these values with cluster-admin rights on the hub, and
`cluster-admins.yaml` grants cluster-admin directly. Anyone who can push to the
deployment repository's branch is therefore cluster-admin on every cluster.
Protect it like the template repository.
