# This fork

`ai-grid-cloud/ai-grid-tenant` branch `cloud-provider` is
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant) `main`
plus the commits listed here. It's rebased onto `main`, never merged, and each
commit explains itself, so it can be offered upstream or dropped on its own.

Base: `kahowell/main` `0e5a15f` (2026-10-29, evening).

Our demo hub (`demo1`) runs this branch with its cluster values and the
provider console's catalog in
[ai-grid-cloud/demo-cluster](https://github.com/ai-grid-cloud/demo-cluster):
an unlabelled hub with no OpenShift AI, `site-a` (role `ingress`) and
`site-b` (role `inference`).

## Carried commits

| Commit | Kind | Upstream form | Drop when |
|---|---|---|---|
| fix(rhoai): install the Cluster Observability Operator on spokes | fix | kahowell #87 | #87 merges |
| fix(maas-db): SCRAM bound to TLS, NetworkPolicy | fix | not yet offered | upstream takes it |
| feat: read cluster values from a deployment repository | structural | needs Sam and Pierangelo | upstream has per-deployment values |
| feat: make keycloak, maas-db and limitador-redis optional | structural | as above | as above |
| feat: deliver a deployment's own catalog; sample models optional | structural | as above | as above |
| feat(console): optional, configured by the deployment | structural | as above | as above |
| feat: ACM's install, its observability and ODF are the deployment's to choose | structural | as above | as above |
| feat: NFD and NVIDIA GPU operator on GPU spokes | feature | not yet offered | upstream installs GPU operators |
| fix: deliver the RHOAI prerequisites Policies to grid members only | fix | not yet offered | upstream stops sending them to every managed cluster |
| fix(gitops): a DSC whose only gap is an aiGrid-only AIGateway is Healthy | workaround | the fix belongs in ai-gateway-operator | that operator reports Ready |
| feat(grid): route each catalog model through a models Gateway | workaround | none: grid discovery routing (praxis-proxy/grid#487) replaces it | grid routes discovered models |
| fix(o11y): let ACM collect OpenShift AI metrics on every site, not the hub | fix | not yet offered (dedicated hub) | upstream applies it per site |
| fix(grid): label peer GridSites for the catalog's routes | workaround | none | with the routing workaround |
| fix(keycloak): set broker claims per IdP, no pass-through | fix | after the structural commits | upstream takes it |
| fix(gitops): 16 GiB for the application controller on a hub with several sites | fix | not yet offered (sizing) | upstream raises the limit |
| chore: point Argo CD at ai-grid-cloud/ai-grid-tenant | fork-only | `scripts/set-tenant-repo.sh` output | never |

`demo1` keeps upstream's default root ApplicationSet shape (`apps/*`, which
excludes `argo-registration` and `maas-home`), not the `dedicated-hub`
profile: that profile moves Keycloak, the `maas-db` primary and Limitador's
Redis to a site labelled `ai-grid/maas-home`, and has no console or catalog.

## Not carried any more (2026-10-29 evening rebase)

- Sites by label and role, and a hub that isn't a site: kahowell #90, #119
  and #120. The fork keeps only the per-site metrics policy listed above.
- Model routes admitted to the inference Gateway by label: kahowell #117.
  The fork also labelled `openshift-ingress`; no route there uses the Gateway.
- The `ai-grid-o11y` namespace: kahowell #118.
- kahowell #114 and #115, picked ahead in the afternoon: now in `main`.
- kahowell #113 is taken as is: the routing dashboard, its user-workload
  federation and the spoke scrape configs are gone from `demo1`.

## Not carried any more (2026-10-29 afternoon rebase)

- The Keycloak fixes: upstream as kahowell #86.
- `preserveResourcesOnDeletion` on the rhoai, provider-gateway and maas-db
  ApplicationSets: upstream as kahowell #111.
- Per-cluster `grid-network` releases, the SWIM key and the hub-only
  `grid-enrollment` app: replaced by `grid-bootstrap`'s Local membership
  (kahowell #89, #92, #103).
- The fork's `grid-provider` ApplicationSet: replaced by upstream's
  `grid-provider-gateway` (kahowell #108).
- A Limitador Redis per ingress spoke: replaced by upstream's shared counters
  on the hub's Redis (`ade946d`).
- The offline render CI: an improvement, kept out of the fork.
