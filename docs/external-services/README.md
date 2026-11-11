# MaaS external services

MaaS depends on a database, an OIDC provider and a Redis. In production the user owns and operates these. This repository installs stand-ins for demos only.

## Demo install

Label one cluster `ai-grid/external-services=true`. [apps/external-services](../../../apps/external-services/README.md) then installs these on it:

| Service | Demo stand-in |
|---|---|
| Database | PostgreSQL through CloudNativePG, `maas-db` |
| OIDC provider | Keycloak |
| Redis for Limitador | `limitador-redis` |
| Secret delivery | External Secrets Operator |

These are not supported for production. They have no backup, sizing or upgrade plan here.

## What MaaS needs

| Service | Where MaaS reads it | Value |
|---|---|---|
| Database | Secret `redhat-ai-gateway-infra/maas-db-config` | `DB_CONNECTION_URL` and `DB_READ_CONNECTION_URL`, PostgreSQL URLs with `sslmode=require` |
| OIDC provider | The inputs `idpIssuerURL` and `idpClientID`, which the tenant Policy ([apps/rhoai/hub/02-ingress-clusters-policy.yaml](../../../apps/rhoai/hub/02-ingress-clusters-policy.yaml)) puts in the AITenant | The issuer URL, a client ID (also the audience) |
| Redis | Secret `kuadrant-system/limitador-redis`, key `URL`, which `Limitador/limitador` references | A `redis://` URL |

The tenant Policy also copies the client secret (the `idpClientSecret*` inputs) into
`models-as-a-service/tenant-demo-oidc-client` and references it from
`AITenant.spec.oidc.clientSecretRef` so the consumer portal auth proxy can use
the same OIDC client as the API.

The MaaS Gateway listener hostname is `<prefix>.<cluster-ingress-domain>`, where
the ingress domain starts with `apps.`. `apps/rhoai/values.yaml` sets the
`maas` prefix, which a site's deployment file, `values/clusters/<cluster>/rhoai.yaml`,
can override, and a target-cluster ConfigurationPolicy appends the cluster's
ingress domain to both listeners.
When the library's Keycloak is selected (`apps/keycloak`, or
`apps/keycloak-external-services` on this cluster), it runs a CronJob that
lists active ingress and combined ManagedClusters, derives the same domain from
each cluster's console claim, and reconciles its own tenant client (`tenant-demo`
in realm `saas`) to exactly those `https://.../oauth2/callback` URIs plus
`http://localhost:8000/callback`. With your own IdP, its client (the
`idpClientID` input) needs the same redirect URIs (`apps/keycloak/README.md`).

## Current limits

Policies write the database Secret and the Redis Secret from the services this
component installs. The tenant Policy takes the IdP from the `idp*` inputs.
Using your own database or Redis means changing those Policies. Nothing here
has run against user-owned services.
