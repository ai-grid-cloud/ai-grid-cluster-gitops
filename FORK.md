# This fork

`ai-grid-cloud/ai-grid-tenant` branch `cloud-provider` is
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant) `main`
plus the commits listed here. It's rebased onto `main`, never merged, and each
commit explains itself, so it can be offered upstream or dropped on its own.

Base: `kahowell/main` `1dd85b5` (2026-10-29).

Our demo hub (`demo1`) runs this branch with its cluster values and the
provider console's catalog in
[ai-grid-cloud/demo-cluster](https://github.com/ai-grid-cloud/demo-cluster):
an unlabelled hub with no OpenShift AI, `site-a` (role `ingress`) and
`site-b` (role `inference`).

## Carried commits

| Commit | Kind | Upstream form | Drop when |
|---|---|---|---|
| fix(rhoai): install the Cluster Observability Operator on spokes | fix | kahowell #87 | #87 merges |
| fix(rhoai): admit model routes to the inference Gateway by label | fix | not yet offered | upstream takes it |
| fix(maas-db): SCRAM bound to TLS, NetworkPolicy | fix | not yet offered | upstream takes it |
| feat: read cluster values from a deployment repository | structural | needs Sam and Pierangelo | upstream has per-deployment values |
| feat: make keycloak, maas-db and limitador-redis optional | structural | as above | as above |
| feat: deliver a deployment's own catalog; sample models optional | structural | as above | as above |
| feat(console): optional, configured by the deployment | structural | as above | as above |
| feat: ACM's install, its observability and ODF are the deployment's to choose | structural | as above | as above |
| feat: NFD and NVIDIA GPU operator on GPU spokes | feature | not yet offered | upstream installs GPU operators |
| fix: deliver the RHOAI prerequisites Policies to grid members only | fix | not yet offered | upstream takes it |
| fix(gitops): a DSC whose only gap is an aiGrid-only AIGateway is Healthy | workaround | the fix belongs in ai-gateway-operator | that operator reports Ready |
| feat(grid): route each catalog model through a models Gateway | workaround | none: grid discovery routing (praxis-proxy/grid#487) replaces it | grid routes discovered models |
| feat: select AI Grid sites by label and role; a hub needn't be a site | structural | kahowell #90 | #90 merges |
| fix(grid): label peer GridSites for the catalog's routes | workaround | none | with the routing workaround |
| fix(o11y): create the ai-grid-o11y namespace for the usage-logs dashboard | fix | not yet offered | upstream takes it |
| fix(keycloak): set broker claims per IdP, no pass-through | fix | after the structural commits | upstream takes it |
| chore: point Argo CD at ai-grid-cloud/ai-grid-tenant | fork-only | `scripts/set-tenant-repo.sh` output | never |

## Not carried any more (2026-10-29 rebase)

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
