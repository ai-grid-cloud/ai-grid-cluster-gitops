# The lab roots' own manifests

Objects that only upstream's lab roots (`bootstrap/applicationset.yaml` and
`bootstrap/dedicated-hub/`) install. Each is an extra source of the component
that used to carry it, so it keeps its Application:

- `rhoai/tenant-idp-lookups.yaml`: the RBAC for the lookups the lab's issuer
  makes (`idpIssuerURL` is a hub template that finds the library's Keycloak),
  synced by `rhoai`.
