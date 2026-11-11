# Appendix A: inputs and values reference

What a deployment repository sets for the library: its root, the 14 inputs, the values files and the ManagedCluster
labels. The deployment template already holds every file here, with the example deployment's values
([deployment template](https://github.com/ai-grid-cloud/ai-grid-deployment-template)).

## Your root

`root/kustomization.yaml` takes the library's `bootstrap/hub` at one commit and patches its ApplicationSet `apps`:

- **The pin.** The full 40-character library SHA goes in three places: the remote base (`//bootstrap/hub?ref=SHA`),
  the first generator's `revision`, and `values.libraryRevision`. The library's URL goes in the first generator's
  `repoURL` and in `values.libraryRepoURL`. The `test` ops fail the render if the library moves a field the patch
  relies on.
- **Generator 0, the library's components.** Its `files` list is your component selection, one line per component:
  `- path: apps/NAME/application.yaml`, except `- path: cluster-config/application.yaml` and the object-storage
  options, `- path: apps/object-storage/s4/application.yaml` and `- path: apps/object-storage/odf/application.yaml`.
  Which lines each hub item takes is in [select components](hub/README.md#select-components).
- **Generator 1, ODF.** Keep it only if you select ODF object storage, and set its `repoURL`, `revision` and `values`
  the same way. Otherwise remove it (`{ op: remove, path: /spec/generators/1 }`).
- **Your own apps.** A generator you add reads `apps/*.yaml` in your deployment repository, one Argo CD Application
  each, in the same format as the library's `apps/*/application.yaml`. Generator fields can't take `@NAME@`, so its
  `repoURL` and `revision` reuse the `deploymentRepoURL` and `deploymentRevision` values through YAML aliases, and its
  `values` reuse the same map (`&inputs`). Your apps use `'@deploymentRepoURL@'` and `'@deploymentRevision@'`, never a
  literal URL.

`root/self.yaml` is Application `deployment-root`, which syncs `root/` from your deployment repository with no
pruning, so the root follows git after `scripts/bootstrap-hub.sh` applies it once.

## Inputs

The library writes each deployment value as `@NAME@`; your root's generator `values` set all 14 once.

| Input | Meaning | Example | Read by |
|---|---|---|---|
| `libraryRepoURL` | The library's repository | `https://github.com/ai-grid-cloud/ai-grid-cluster-gitops.git` | every component (self-references) |
| `libraryRevision` | The pinned commit, a full 40-character SHA | `LIBRARY_SHA` | every component |
| `deploymentRepoURL` | Your deployment repository | `https://github.com/my-org/ai-grid-deployment.git` | `cluster-config`, `grid-bootstrap`, `rhoai` (the `values/` files) |
| `deploymentRevision` | Its branch or commit | `main` | the same |
| `catalogRepoURL` | Your catalog repository | `https://github.com/my-org/ai-grid-catalog.git` | `acm-models`, `console` (git writer) |
| `catalogRevision` | Its branch: the git writer pushes to it, so use a branch | `main` | `acm-models`, `console` |
| `idpIssuerURL` | The tenant OIDC issuer | `https://keycloak-tenant-idp.HUB_APPS_DOMAIN/realms/tenants` | `rhoai` (the tenant Policy and the sites' AITenant) |
| `idpClientID` | The tenant client; MaaS matches the token's `azp` against it | `ai-grid-tenants` | `rhoai` |
| `idpClientSecretNamespace` | Namespace of the hub Secret with that client's secret | `tenant-idp-client` | `rhoai` (the tenant Policy) |
| `idpClientSecretName` | That Secret's name | `tenant-idp-client` | `rhoai` (the tenant Policy) |
| `idpClientSecretKey` | Its key | `client-secret` | `rhoai` (the tenant Policy) |
| `idpCANamespace` | Namespace of the hub ConfigMap with the CA that signs the issuer's certificate | `openshift-config-managed` | `rhoai` (the tenant Policy) |
| `idpCAName` | That ConfigMap's name | `default-ingress-cert` | `rhoai` (the tenant Policy) |
| `idpCAKey` | Its key | `ca-bundle.crt` | `rhoai` (the tenant Policy) |

Rules:

- Every input is required. In the cluster, an input you don't set makes the root report `missing input: NAME`, and a
  value that's empty or contains `"`, `'`, `\` or `@` reports `invalid input: NAME`; either way the root creates no
  Applications.
- A bare render of the library's `bootstrap/hub` shows each input as `REQUIRED-NAME`, in the `values` of both
  generators, plus the library URL and revision in each generator's own `repoURL` and `revision`, and the root's own
  check for leftover markers.
- `scripts/check-deployment.sh DEPLOYMENT_DIR` renders your root before you push and reports
  `unset inputs: NAME ...` for any input still unset or still `REQUIRED-NAME`, and
  `placeholders left in your files:` for any `REQUIRED-NAME` left in your repository's other YAML or JSON files.
- If you use the library's Keycloak, set the `idp*` inputs to the values its page gives
  ([Keycloak](hub/04-tenant-identity.md#keycloak)); with your own IdP, they point at it
  ([tenant identity provider](hub/04-tenant-identity.md#tenant-identity-provider)).

`bootstrap/hub/README.md` documents the same contract for library maintainers.

## Files your deployment repository holds

| File | Required | Read by | Content |
|---|---|---|---|
| `root/kustomization.yaml` | Yes | `deployment-root` | The pin, the selection, the inputs ([your root](#your-root)) |
| `root/self.yaml` | Yes | `scripts/bootstrap-hub.sh` | Application `deployment-root` |
| `values/cluster-admins.yaml` | Yes | `cluster-config` | `cluster_admins:` list of user names, or `[]` ([cluster sign-in and admins](hub/00-platform-services.md#cluster-sign-in-and-admins)) |
| `values/grid-bootstrap.yaml` | Yes | `grid-bootstrap` | `external.certManager.ca.mode` (`Generate` or `Existing`); `managedClusters.createClusterSetBinding` (default `true`) ([grid bootstrap](hub/02-grid.md#grid-bootstrap)) |
| `values/clusters/SITE/rhoai.yaml` | No; add it before you label the site | `rhoai` | Values for one site, such as `components.aigateway.modelsAsAService.gateway.annotations.ai-grid/maas-gateway-hostname-prefix` (default `maas`) or the gateway's `spec.listeners` for its certificate ([MaaS gateway certificate](spokes/maas-certificate.md)) |
| `apps/*.yaml` | No | your root's own-apps generator | Your own Applications; they may use `@NAME@` inputs |

## ManagedCluster labels

| Label | Values | Effect |
|---|---|---|
| `ai-grid/enabled` | `true` | Makes the cluster a grid site |
| `ai-grid/role` | `ingress`, `inference`, `combined` | What the site installs; without it nothing installs |
| `location` | Your choice | Shown in the console; model placement can select it |
| `ai-grid/metallb-pool` | `FIRST-LAST` | A MetalLB address range ([load balancers](spokes/networking.md#load-balancers)) *(Unverified.)* |
| `ai-grid/external-services` | `true` | Runs MaaS's shared state on that cluster instead of the hub *(Unverified.)* |
