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
each `application.yaml`. The `rhoai` ApplicationSet receives them as cluster
generator values (`apps/rhoai/application.yaml`). With none set, a deployment
reads this directory, so this repository deploys exactly as before.

## Layout

| Path | Used by | Required |
|---|---|---|
| `rhoai.yaml` | The `rhai-on-openshift` release on every cluster, after `apps/rhoai/values.yaml`. | No |
| `clusters/<cluster>/rhoai.yaml` | The same release on one cluster: its consumer backends. | No |
| `clusters/<cluster>/provider-gateway.yaml` | The cluster's grid provider gateway: Route host, model backends. Its presence installs the gateway (`apps/rhoai/hub/04-provider-gateway-applicationset.yaml`). | No |
| `hub/` | Objects applied to the hub only, such as declared peers. The directory must exist. | Yes |
| `cluster-admins.yaml` | `cluster-config`: users granted `cluster-admin`. `cluster_admins: []` grants no one. | Yes |

`<cluster>` is the ACM ManagedCluster name (`local-cluster` for the hub).

## Who can change a cluster through this repository

Argo CD applies these values with cluster-admin rights on the hub, and
`cluster-admins.yaml` grants cluster-admin directly. Anyone who can push to the
deployment repository's branch is therefore cluster-admin on every cluster.
Protect it like the template repository.
