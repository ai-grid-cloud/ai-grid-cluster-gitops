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
| `rhoai.yaml` | The `rhai-on-openshift` release on every spoke, after `apps/rhoai/values.yaml` and the role file. | No |
| `clusters/<cluster>/rhoai.yaml` | The same release on one spoke: its grid consumer's backends. | Yes, on every ingress and combined spoke (the consumer refuses an empty list) |
| `clusters/<cluster>/provider-gateway.yaml` | The spoke's grid provider gateway: trusted peers, Route host, model backends. | Yes, on every inference and combined spoke |
| `clusters/<cluster>/grid-network.yaml` | The spoke's GridNetwork record (`enabled: true` once it holds its enrolled identity). | No |
| `clusters/<cluster>/manifests/*.yaml` | Objects applied to that spoke alone, such as the hub's declared peers. | No |
| `grid-enrollment.yaml` | The hub's grid enrollment (`apps/grid-enrollment`): `host`, the enrollment Route's hostname. | Yes |
| `apps/<name>.yaml` | One Argo CD Application per optional app the deployment runs: `keycloak`, `maas-db`, `limitador-redis`. Same format as `apps/*/application.yaml`; `@templateRepoURL@` names this repository. | No: an app not listed doesn't run |
| `keycloak/` | A kustomize overlay of `apps/keycloak`: the realms (`keycloak-realm-import`) and the generated secrets their placeholders need. Keycloak's public URL isn't a value: it's the Route's assigned host (`apps/keycloak/README.md`). Another repository names the base remotely, `https://github.com/kahowell/ai-grid-tenant//apps/keycloak?ref=cloud-provider`. | With `apps/keycloak.yaml` |
| `cluster-admins.yaml` | `cluster-config`: users granted `cluster-admin`. `cluster_admins: []` grants no one. | Yes |

`<cluster>` is the ACM ManagedCluster name (`local-cluster` for the hub).

## Spokes are chosen by label

Which clusters run AI Grid isn't in git: a cluster becomes a spoke when its
ManagedCluster is labelled, and stops being one when the label goes
(`apps/ai-grid-spokes/README.md`). This deployment's hub is also a combined
spoke, and so is `ai-grid-2`:

```sh
oc label managedcluster local-cluster ai-grid/enabled=true ai-grid/role=combined
oc label managedcluster ai-grid-2 ai-grid/enabled=true ai-grid/role=combined
```

## Upgrading a cluster built before the deployment repository

These changes are written for a fresh bootstrap. A running cluster needs two
steps first:

1. **Rerun `bootstrap.sh`** before Argo CD reads this revision. Only that
   script applies the root ApplicationSet. An old root leaves the `@…@`
   tokens unreplaced, and it deletes `keycloak`, `maas-db` and
   `limitador-redis`, which no longer sit under `apps/*/application.yaml`.
2. **Expect objects to change owner.** Grid enrollment moves from
   `rhoai-local-cluster` to `grid-enrollment`, the provider gateway from
   `rhoai-<cluster>` to `grid-provider-<cluster>`, and the sample model from
   `facebook-opt-125m-<cluster>` to `facebook-opt-125m-{inference,ingress}-<cluster>`.
   If an old Application syncs before the new one adopts, it prunes them:
   enrollment is down until the new app recreates it (its database PVC is
   kept). To avoid that, pause automated sync on the old Applications for the
   switch.

## Who can change a cluster through this repository

Argo CD applies these values with cluster-admin rights on the hub, and
`cluster-admins.yaml` grants cluster-admin directly. Anyone who can push to the
deployment repository's branch is therefore cluster-admin on every cluster.
Protect it like the template repository.
