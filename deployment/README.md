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
| `rhoai.yaml` | The `rhai-on-openshift` release on every cluster, after `apps/rhoai/values.yaml`. Sets `grid-enrollment.host`. | No |
| `clusters/<cluster>/rhoai.yaml` | The same release on one cluster: its consumer backends. | No |
| `clusters/<cluster>/provider-gateway.yaml` | The cluster's grid provider gateway: peers, Route host, model backends. | Yes, for every cluster the `rhoai` ApplicationSet selects |
| `clusters/<cluster>/grid-network.yaml` | The cluster's GridNetwork record (`enabled: true` once it holds its enrolled identity). | No |
| `hub/` | Objects applied to the hub only, such as declared peers. The directory must exist. | Yes |
| `apps/<name>.yaml` | One Argo CD Application per optional app the deployment runs: `keycloak`, `maas-db`, `limitador-redis`. Same format as `apps/*/application.yaml`; `@templateRepoURL@` names this repository. | No: an app not listed doesn't run |
| `keycloak/` | A kustomize overlay of `apps/keycloak`: the realms (`keycloak-realm-import`) and the generated secrets their placeholders need. Keycloak's public URL isn't a value: it's the Route's assigned host (`apps/keycloak/README.md`). Another repository names the base remotely, `https://github.com/kahowell/ai-grid-tenant//apps/keycloak?ref=cloud-provider`. | With `apps/keycloak.yaml` |
| `cluster-admins.yaml` | `cluster-config`: users granted `cluster-admin`. `cluster_admins: []` grants no one. | Yes |

`<cluster>` is the ACM ManagedCluster name (`local-cluster` for the hub).

## Who can change a cluster through this repository

Argo CD applies these values with cluster-admin rights on the hub, and
`cluster-admins.yaml` grants cluster-admin directly. Anyone who can push to the
deployment repository's branch is therefore cluster-admin on every cluster.
Protect it like the template repository.
