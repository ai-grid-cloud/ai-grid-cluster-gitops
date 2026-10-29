# MaaS home

A dedicated hub runs no MaaS state. One site holds it instead: the cluster
labelled `ai-grid/maas-home=true`.

```sh
oc label managedcluster site-a ai-grid/maas-home=true
```

The `maas-home` ApplicationSet installs these on it, reusing each app's
manifests:

| Component | From |
|---|---|
| External Secrets Operator | `apps/external-secrets/manifests` |
| `maas-db` primary | `apps/maas-db/local-cluster`, without its ServiceExport |
| Keycloak | `apps/keycloak`, without the hub's public-URL Policy |
| Limitador's Redis | `apps/limitador-redis/manifests`, without its ServiceExport |

The hub Policies here give the home its Keycloak public URL and `maas-api`'s
database connection, both read from the home's own Route and Secrets. The
tenant Policy (`apps/rhoai/hub`) finds Keycloak on the home through its
console-URL cluster claim.

The label selects the home through Argo CD's cluster Secret, which ACM never
removes a label from, and the ApplicationSet preserves what it installed, so
removing the label deletes nothing. Moving the home means moving its database.

Label one cluster, normally also an AI Grid site with role `ingress` or
`combined`. Other ingress sites don't get a read replica or database
credentials yet: both are copied from Secrets on the hub, where a dedicated
hub has none.
