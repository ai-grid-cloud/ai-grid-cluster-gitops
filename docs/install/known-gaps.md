# Known gaps

What this release of the library doesn't do yet. Each is a candidate for a library change.

| Gap | Effect | Today |
|---|---|---|
| No input for the MaaS gateway's client-facing certificate | Tenants see the in-cluster service certificate | A per-site values override and your own Certificate ([MaaS gateway certificate](spokes/maas-certificate.md)) |
| The MaaS gateway's port 80 listener serves MaaS in cleartext | Calls can be made without TLS | Chart default; not changed |
| No object-storage input for Loki | `ai-grid-o11y` and `ai-grid-usage-logs` need ODF's NooBaa and AWS `gp3-csi`; without them the console's **Monitoring** page reports that `redhat-ods-monitoring` doesn't exist | Skip them ([observability](hub/07-observability.md)) |
| No per-cluster values for MetalLB from the deployment | Bare-metal sites can't set pools from your repository | Labels only ([load balancers](spokes/networking.md#load-balancers)) |
| Keycloak's import-then-start layout | A Keycloak version change can't migrate its database | `Recreate`, backups ([Keycloak](hub/04-tenant-identity.md#keycloak)) |
| The console can't create organizations on Red Hat build of Keycloak 26.4 or 26.6 | Organizations need community Keycloak 26.8.0 | Community Keycloak |
| The library Keycloak's client secret shares a Secret with its admin password | The tenant Policy can read the admin password | Bring your own IdP with a dedicated Secret |
| No bring-your-own MaaS database or Redis | Both run from the library | Use ours |
| Withdrawing a site from the grid | Removing `ai-grid/enabled` stops managing the site and removes its tenant access, but its GridSite stays `Connected` and `Available` | Uninstall the site ([uninstall AI Grid](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/08-uninstall.md#3-uninstall-each-site)) |
| A hub that is also a site can't be uninstalled by the script | The template's `scripts/uninstall.sh` refuses while `local-cluster` is labelled `ai-grid/enabled` | Unlabel it and wipe it by hand like a site, then run the hub step |
| Hub sizing not established | | Size from the tested hub's components |
| The registry pull secret and image mirror can't be skipped | They ride in `rhoai-prerequisites` with what every install needs, so every cluster gets the `quay.io/rhoai` pull-secret entry, the catalog pull secret and the image mirror; a GA install pulls from `registry.redhat.io` with the cluster's own pull secret and needs none of them | Leave them in; they should become an optional component in the upstream series (overlaps [cluster-gitops #230](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/pull/230) and [#231](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/pull/231)) |
| No GA catalog path | OpenShift AI installs from a pre-release catalog on `quay.io/rhoai`, and the mirror sends `registry.redhat.io/rhaii*` to `registry.stage.redhat.io` with `NeverContactSource`; both need early-access logins | Pre-release access from Red Hat ([OpenShift AI prerequisites](hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)); the GA path is undecided |
| Redis counters can't be turned off | Every ingress site's Limitador is enforced onto the hub's Redis | Select `apps/limitador-redis` ([rate-limit counters](hub/03-maas-shared-services.md#limitadors-redis)) |
| The library Keycloak's redirect URIs assume prefix `maas` | Another MaaS hostname prefix breaks portal sign-in | Use `maas` with the library Keycloak ([Keycloak](hub/04-tenant-identity.md#keycloak)) |
| The console works only with Keycloak | With another OIDC provider there's no console | Skip the console; write the catalog yourself ([provider console](hub/05-console-and-model-delivery.md#provider-console)) |
