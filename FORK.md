# This fork

`ai-grid-cloud/ai-grid-tenant` is a fork of
[kahowell/ai-grid-tenant](https://github.com/kahowell/ai-grid-tenant), the AI
Grid reference deployment. Its default branch, `cloud-provider`, is the
reference's `main` plus the commits in the table below.

Update this file on every rebase: the table, the merged history, and the base
commit.

Base: `kahowell/main` at `52e7ded`.

## Why it exists

The fork is the test bed for changes we offer upstream. Our demo clusters run
it: `demo1` is an ACM hub with no OpenShift AI, `demo2` (ManagedCluster
`site-a`) is an ingress spoke, and `demo3` (`site-b`) is an inference-only
spoke. A change runs here first, and goes upstream as its own pull request
once it has worked.

The clusters' own values (hostnames, image pins, the catalog the provider
console writes) aren't in this repository. They're in
[ai-grid-cloud/demo-cluster](https://github.com/ai-grid-cloud/demo-cluster),
which `bootstrap.sh` names as the deployment repository.

## Branch model

- `main` is always `kahowell/main`. `cloud-provider` is rebased onto it,
  never merged.
- Each commit is one reviewable change: one fix or feature, with a message
  that says why it exists, what it changes, what it affects on the hub and
  on spokes, and its category. Upstream candidates come first, directly on
  `main`, so each can be offered as it is.
- Every commit renders with `make render`, 0 errors, on its own.

To rebase:

1. Fetch `kahowell/main` and rebase `cloud-provider` onto it. Drop commits
   that went upstream.
2. Run `make render` at every commit.
3. Render the demo deployment and compare it with what `demo1` runs
   (`hack/render/render.py --deployment <demo-cluster checkout> --dump`). If an
   object moves to another Application under the same name, untrack it first:
   mark it with `argocd.argoproj.io/sync-options: Prune=false,Delete=false`,
   push, let the new Application adopt it, then remove the mark. Otherwise the
   old Application deletes it.
4. If a kustomize patch in `demo-cluster` targets an object that was renamed,
   update the patch in the same change. A patch whose target matches nothing
   is skipped without an error.
5. Force-push `cloud-provider` with a lease. `demo1`'s Argo CD follows the
   branch, so the push is a change to `demo1`.
6. Update this file.

## Carried commits

In branch order. Categories: **upstream candidate** (offer as it is),
**structural** (changes the layout or how clusters are selected; needs the
conversation with Sam Batschelet and Pierangelo Di Pilato first), **fork-only**
(never offered).

| Commit | Why it's needed | Category | Status | Dropped when |
|---|---|---|---|---|
| chore: render every Application offline, in CI | No check exists between a commit and a hub | upstream candidate | not yet offered | merged upstream |
| fix(rhoai): install the Cluster Observability Operator on spokes | Spokes get no monitoring stack, so no MaaS usage metrics | upstream candidate | not yet offered | merged upstream |
| fix(keycloak): don't rotate generated secrets on a spec change | A spec change rotates the admin password Keycloak never applies | upstream candidate | not yet offered | merged upstream |
| fix(keycloak): publish the public URL only on the hub | The Policy fails on spokes without maas-db and blocks Keycloak's sync | upstream candidate | not yet offered | merged upstream |
| fix(rhoai): admit model routes to the inference Gateway by label | Every new model namespace needs a values edit | upstream candidate | not yet offered | merged upstream |
| fix(maas-db): SCRAM bound to TLS, NetworkPolicy | Any hub pod reaches the database of every tenant's API keys | upstream candidate | not yet offered | merged upstream |
| fix(limitador-redis): require a password | Rate-limit counters are writable by anyone who reaches Redis | upstream candidate | not yet offered | merged upstream |
| fix(limitador-redis): never delete Kuadrant's Limitador with this app | Removing the app deletes the cluster's rate limiter | upstream candidate | not yet offered | merged upstream |
| feat: read cluster values from a deployment repository | A deployment has to fork and rewrite about six files | structural | not yet offered | upstream reads values from outside the tree |
| feat: make keycloak, maas-db and limitador-redis optional | A deployment with its own IdP or database can't leave these out | structural | not yet offered | upstream makes them optional |
| feat: select clusters by ai-grid labels and role | The console adds clusters by label; sites can be inference-only | structural | not yet offered | upstream selects by label and role |
| feat: deliver a deployment's own catalog; sample models optional | Each deployment has its own catalog | structural | not yet offered | upstream takes the catalog as a value |
| feat(console): optional, configured by the deployment | Not every deployment runs the console | structural | not yet offered | upstream makes the console optional |
| feat: ACM's install, its observability and ODF are the deployment's to choose | Our hub's ACM has another Subscription; it has no ODF | structural | not yet offered | upstream makes them optional |
| fix(keycloak): set broker claims per IdP, no pass-through | A tenant IdP can claim another organization's ID and groups | upstream candidate, after the structural commits | not yet offered | merged upstream, or ported to `apps/keycloak` |
| feat: NFD and NVIDIA GPU operator on GPU spokes | GPU models need the operator; the reference is CPU-only | upstream candidate, after the structural commits | not yet offered | merged upstream |
| feat(limitador-redis): a Redis on each ingress spoke, for its own Limitador | A hub without OpenShift AI has no Limitador of its own | upstream candidate, after the structural commits | not yet offered | merged upstream |
| fix: Remove stops managing a spoke, it doesn't uninstall it | Console Remove would uninstall OpenShift AI | fork-only (upstream in kahowell #90) | not offered on its own | #90 merges |
| chore: point Argo CD at ai-grid-cloud/ai-grid-tenant | The fork's Argo CD must read `cloud-provider` | fork-only | never offered | the template's own URL becomes a deployment value |
| docs: describe this fork | This file | fork-only | never offered | the fork goes away |

## Merged upstream

| kahowell PR | What | Merged |
|---|---|---|
| [#72](https://github.com/kahowell/ai-grid-tenant/pull/72) | Provider console on the hub: catalog delivery and status, `ai-grid-ready`, the console | 2026-10-28 |
| [#79](https://github.com/kahowell/ai-grid-tenant/pull/79) | Bind each Policy in its own sync wave | 2026-10-28 |
| [#80](https://github.com/kahowell/ai-grid-tenant/pull/80) | Add cchase to the `cluster-admins` Group | 2026-10-28 |
| [#82](https://github.com/kahowell/ai-grid-tenant/pull/82) | Trust the console backend's Keycloak user by its recorded id; give it an email | 2026-10-28 |
