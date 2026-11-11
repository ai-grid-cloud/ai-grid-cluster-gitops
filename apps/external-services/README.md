# External services

A dedicated hub runs MaaS state itself. This app is the alternative, where one
site holds it instead: the cluster labelled `ai-grid/external-services=true`. These services are demo stand-ins for
ones the user owns in production. See
[external services](../../docs/external-services/README.md).

```sh
oc label managedcluster site-a ai-grid/external-services=true
for app in external-services keycloak-external-services; do
  sed -e 's|@libraryRepoURL@|https://github.com/ai-grid-cloud/ai-grid-cluster-gitops.git|g' \
      -e 's|@libraryRevision@|HEAD|g' "apps/$app/application.yaml" | oc apply -f -
done
```

The Applications name this repository as `@libraryRepoURL@` at
`@libraryRevision@`, so replace both as you apply them: a fork uses its own URL
and revision. Leave out `keycloak-external-services` if the site doesn't run the
library's Keycloak.

No root ApplicationSet generates these apps, so a hub that runs MaaS state itself
carries no external-services Placement.

The `external-services` ApplicationSet installs these on it, reusing each app's
manifests:

| Component | From |
|---|---|
| External Secrets Operator | `apps/external-secrets/manifests` |
| `maas-db` primary | `apps/maas-db/primary`, without its ServiceExport |
| Limitador's Redis | `apps/limitador-redis/manifests`, without its ServiceExport |

The hub Policy here gives this cluster `maas-api`'s database connection, read
from this cluster's own Secrets.

The library's Keycloak isn't part of this component. To run it on this cluster
too, also select `apps/keycloak-external-services`: it installs `apps/keycloak`
here, without the hub's public-URL Policy, and binds its own public-URL Policy
to this component's Placement. Either way the tenant Policy (`apps/rhoai/hub`)
reads the issuer from the `idpIssuerURL` input.

The label selects this cluster through Argo CD's cluster Secret, which ACM never
removes a label from, and the ApplicationSet preserves what it installed, so
removing the label deletes nothing. Moving this cluster means moving its database.

Label one cluster, normally also an AI Grid site with role `ingress` or
`combined`. Other ingress sites don't get a read replica or database
credentials yet: both are copied from Secrets on the hub, where a dedicated
hub has none.
