# MaaS shared services

MaaS on every ingress or combined site shares two services: the MaaS database primary, the system of record for API
keys and subscriptions, and the Redis that holds the rate-limit counters. They aren't part of the hub's control plane:
the sites reach them through Submariner, so they run on the hub by default or on one labelled site
([run them on a site](#run-the-shared-services-on-a-site)). Running your own isn't supported yet
([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)); what MaaS reads from each is in [MaaS external services](../../external-services/README.md).

| | |
|---|---|
| Options | No choice: both run from the library. Optionally, run them on one labelled site instead of the hub ([external services](#run-the-shared-services-on-a-site)). |
| Example chose | Ours, on the hub; `apps/external-services` selected with no cluster labelled |
| Requires | Submariner, to export them ([ACM](01-acm.md#submariner)); Argo CD registration and the OpenShift AI prerequisites from [site delivery](06-site-delivery.md); a default StorageClass on the hub and every ingress or combined site |

## Select it

```yaml
- path: apps/maas-db/application.yaml
- path: apps/limitador-redis/application.yaml
```

Add `- path: apps/external-services/application.yaml` only to run them on a site
([external services](#run-the-shared-services-on-a-site)).

## MaaS database

The MaaS database is the PostgreSQL system of record for every organization's API keys and subscriptions: a writable
primary on the hub and a read replica on each ingress or combined site. MaaS (`maas-api`) on every ingress or combined
site depends on it, and so does the library's Keycloak, which keeps its own database in the same cluster.

| | |
|---|---|
| Runs on | hub (primary); ingress and combined sites (read replicas) |
| Library component | `apps/maas-db` (select `apps/maas-db/application.yaml`) |
| Choices | Use ours · Bring your own (not supported yet) |

### Use ours

1. Select `apps/maas-db/application.yaml` ([select it](#select-it)).

2. Select [ACM](01-acm.md#red-hat-advanced-cluster-management) and `apps/argo-registration`. Replicas reach the primary through Submariner, and the
   ApplicationSet picks sites from Argo CD's cluster Secrets.
3. Make sure the hub and every ingress or combined site have a default StorageClass. Each database instance claims
   20 GiB.

The component reads only `libraryRepoURL` and `libraryRevision`, no file from your deployment repository, and no
Secret you create: CloudNativePG generates every credential on the hub. It creates:

| Where | What |
|---|---|
| Hub, namespace `maas-db` | The CloudNativePG operator (`cloudnative-pg`, channel `stable-v1`, catalog `certified-operators`, in `cnpg-system`); `Cluster` `maas-db`, 3 instances, database `maas`, owner `maas_api`; ServiceExport `maas-db-rw`; read Services `maas-read-ro` and `maas-read-r` |
| Each ingress or combined site, namespace `maas-db` | The operator and `Cluster` `maas-read`, one instance, streaming from `maas-db-rw.maas-db.svc.clusterset.local` with `sslmode=verify-full` |
| Each ingress or combined site, namespace `redhat-ai-gateway-infra` | Secret `maas-db-config` with `DB_CONNECTION_URL` (the primary, through Submariner) and `DB_READ_CONNECTION_URL` (the local replica, `maas-read-r`), written by Policy `maas-db-api-credentials` |

ACM Policy `maas-db-replication-secrets` copies the replication certificate, CA and application credentials from the
hub to each remote site. The primary, its operator and its ServiceExport carry `Delete=false`, so removing the
Application or the hub's labels never deletes the database. A site's replica goes with the site's Application when the
site leaves the grid or the ingress role. Details: [`apps/maas-db/README.md`](../../../apps/maas-db/README.md).

#### Verify

On the hub:

```sh
oc get clusters.postgresql.cnpg.io -n maas-db
oc get policies.policy.open-cluster-management.io -n maas-db
oc get applications.argoproj.io -n openshift-gitops | grep maas-db
```

On each ingress or combined site:

```sh
oc --context SITE_CONTEXT get cluster maas-read -n maas-db -o jsonpath='{.status.phase}{"\n"}'
oc --context SITE_CONTEXT get secret maas-db-config -n redhat-ai-gateway-infra -o custom-columns=NAME:.metadata.name,TYPE:.type
```

Replace `SITE_CONTEXT` with the site's kubeconfig context.

You should see `maas-db` with 3 ready instances, both Policies `Compliant`, Applications `maas-db`,
`maas-db-local-cluster` and `maas-db-<site>` Synced and Healthy, `Cluster in healthy state` on the site, and the
`maas-db-config` Secret. Until the first site joins, `maas-db-local-cluster` stays unhealthy: its ServiceExport gets no
global IP without a Submariner connection. This is expected.

### Bring your own

Not supported yet. MaaS reads only Secret `redhat-ai-gateway-infra/maas-db-config` on each ingress or combined site,
with two keys:

- `DB_CONNECTION_URL`: a `postgresql://` URL to the writable database, with `sslmode=require`
- `DB_READ_CONNECTION_URL`: a `postgresql://` URL to a read-only endpoint close to the site, with `sslmode=require`

The library writes that Secret from its own CloudNativePG cluster, and has no input that points it at another database.
To use your own PostgreSQL, leave `apps/maas-db` out and deliver `maas-db-config` to each ingress or combined site
yourself, for example with your own ACM Policy reading your credentials. The library's Keycloak still needs
`apps/maas-db`. Nothing in the library has run against a user-owned database. See [Gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md).
*(Unverified.)*

### Skip

You can't skip it. Without `maas-db-config`, `maas-api` on the ingress and combined sites has no database, and no
organization can create API keys or call a model.

### Upgrade

The database moves with the library pin like any other component. The operator follows channel `stable-v1` with
automatic approval. The library configures no backups or point-in-time recovery; add them before you hold production
data. To move an existing database into this one, export and restore it into the primary before the credentials Policy
points `maas-api` at it ([`apps/maas-db/README.md`](../../../apps/maas-db/README.md), "Rollout").

### Known issues

- **Symptom:** `maas-db-local-cluster` reports a ServiceExport without a global IP on a new hub.
  **Cause:** Submariner has no connection until a site joins.
  **Workaround:** None needed. It turns Healthy after the first site joins.
- **Symptom:** On a fresh install, a site's `maas-api` can't read for a few minutes.
  **Cause:** The credentials Policy can write `maas-db-config` before the replica's `maas-read-r` Service exists.
  **Workaround:** None needed. Reads succeed once the replica is up.

## Limitador's Redis

Limitador's Redis holds the rate-limit counters that every MaaS gateway in the grid shares, so a subscription's token
quota counts across all ingress sites instead of per site. Limitador on each ingress or combined site depends on it,
through a Submariner ServiceExport.

| | |
|---|---|
| Runs on | hub (Redis); ingress and combined sites (Limitador points at it) |
| Library component | `apps/limitador-redis` (select `apps/limitador-redis/application.yaml`) |
| Choices | Use ours. Bring your own and Skip are not supported yet. |

### Use ours

1. Select `apps/limitador-redis/application.yaml` ([select it](#select-it)).

2. Select [ACM](01-acm.md#red-hat-advanced-cluster-management) (for Submariner) and `apps/rhoai-prerequisites`, whose Policy `rhoai-limitador-redis` points
   each site's Limitador at this Redis.
3. Make sure the hub has a default StorageClass. Each Redis instance claims 10 GiB.

The component reads only `libraryRepoURL` and `libraryRevision`, no file from your deployment repository, and no
Secret you create. It creates:

| Where | What |
|---|---|
| Hub, namespace `limitador-redis` | The OpsTree Redis operator (`redis-operator`, channel `stable`, catalog `community-operators`); `RedisReplication` `limitador-redis` (3 Redis instances with 3 Sentinels, `maxmemory 6gb`, `noeviction`, image `registry.redhat.io/rhel9/redis-7`); NetworkPolicy `limitador-redis-isolation`; ServiceExport `limitador-redis-master` |
| Hub, namespace `kuadrant-system` | Secret `limitador-redis` (key `URL`) and the storage reference on `Limitador` `limitador` |
| Each ingress or combined site (Policy `rhoai-limitador-redis`) | Namespace `limitador-redis` for the ServiceImport, Secret `kuadrant-system/limitador-redis` with `URL: redis://limitador-redis-master.limitador-redis.svc.clusterset.local:6379`, and `Limitador` `limitador` storage set to that Secret |

The NetworkPolicy admits the Redis pods themselves, Limitador on the hub, and Submariner Globalnet addresses
(`242.0.0.0/8`). Redis has no password: any workload that reaches it through Submariner can read and write the
counters. Details: [`apps/limitador-redis/README.md`](../../../apps/limitador-redis/README.md) and
[`apps/rhoai-prerequisites/README.md`](../../../apps/rhoai-prerequisites/README.md), "Shared Limitador Redis".

#### Verify

On the hub:

```sh
oc get redisreplication limitador-redis -n limitador-redis
oc get serviceexport limitador-redis-master -n limitador-redis
oc get applications.argoproj.io limitador-redis -n openshift-gitops
```

On each ingress or combined site:

```sh
oc --context SITE_CONTEXT get serviceimport limitador-redis-master -n limitador-redis
oc --context SITE_CONTEXT get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage.redis.configSecretRef.name}{"\n"}'
```

Replace `SITE_CONTEXT` with the site's kubeconfig context.

You should see the ServiceExport and ServiceImport, `limitador-redis` as the storage Secret, and the Application Synced
and Healthy. Until the first site joins, `limitador-redis` stays unhealthy: the ServiceExport CRD arrives with
Submariner. This is expected.

With two or more ingress sites, exhaust a subscription's token quota through one site's gateway, then call another
site's gateway: the call returns HTTP `429` at once. *(Unverified.)* The verified install had one site.

### Bring your own

Not supported yet. Limitador reads Secret `kuadrant-system/limitador-redis`, key `URL` (a `redis://` URL), on each
ingress or combined site. Policy `rhoai-limitador-redis` writes that Secret with the library's Submariner address, and
the library has no input for another Redis. To use your own, leave `apps/limitador-redis` out and deliver the Secret and
the `Limitador` storage reference to each site yourself; `apps/rhoai-prerequisites` still writes its own, so you'd have
to change that Policy too. See [Gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md). *(Unverified.)*

### Skip

You can't skip it today. `apps/rhoai-prerequisites` enforces Policy `rhoai-limitador-redis` on every ingress and
combined site: it writes Secret `kuadrant-system/limitador-redis` and sets each site's Limitador storage to that Redis.
Without this component, Limitador points at a Redis that doesn't exist, and the Policy puts the setting back if you
remove it. Making Redis optional, so counters stay local to each site, needs a library change
([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).

### Upgrade

Redis moves with the library pin. The Redis image is pinned by digest in the library. The operator follows the
community channel `stable` with automatic approval.

### Known issues

- **Symptom:** `limitador-redis` is unhealthy on a new hub.
  **Cause:** The ServiceExport CRD comes with Submariner, which connects only after a site joins.
  **Workaround:** None needed. It turns Healthy after the first site joins.
- **Symptom:** Limitador on a site can't reach Redis.
  **Cause:** Submariner between the hub and the site isn't connected.
  **Workaround:** Check the Submariner add-on and the gateway ports; see [Submariner](01-acm.md#submariner).

## Run the shared services on a site

By default the hub runs MaaS's shared state. `apps/external-services` is the alternative: one site, the cluster you
label `ai-grid/external-services=true`, runs the MaaS database primary, Redis and the External Secrets Operator
instead. Without a labelled cluster it installs nothing. *(Unverified.)*

```sh
oc label managedcluster SITE ai-grid/external-services=true
```

Replace `SITE` with the ManagedCluster name, normally an AI Grid site with role `ingress` or `combined`. To run the
library's Keycloak there too, also select `apps/keycloak-external-services` ([tenant identity](04-tenant-identity.md#use-ours-1)).
Removing the label deletes nothing, and moving that cluster means moving its database. The
[README](../../../apps/external-services/README.md) has the details and limits.
