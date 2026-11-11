# The hub's root, for a deployment repository

This directory is the root ApplicationSet of an AI Grid hub. This repository
doesn't apply it to any cluster: a deployment repository takes it as a
kustomize remote base at a pinned commit, selects components, and sets every
input once. Argo CD then installs each selected component from this
repository at that commit.

## What a deployment patches

`applicationset.yaml` marks each field a deployment owes as `REQUIRED-<name>`.
Generator fields can't be templated, so the deployment's kustomization patches
them with JSON patches:

| Path | Set to |
|---|---|
| `/spec/generators/0/git/repoURL` | this repository's URL (the `libraryRepoURL` input) |
| `/spec/generators/0/git/revision` | the pinned commit, a full SHA (the `libraryRevision` input) |
| `/spec/generators/0/git/files` | the components the deployment selects, as `- path: apps/<name>/application.yaml` |
| `/spec/generators/0/git/values` | every input (table below) |
| `/spec/generators/1` | ODF: the same three fields under `matrix/generators/0/git`, or remove the generator |

A deployment's own apps go in a generator it appends. That generator needs the
same `values`, because the `templatePatch` reads them for every Application.

## Inputs

Components write an input as `@<name>@`. The `templatePatch` replaces each one
from the generator's `values`. When an Application still holds `@<name>@` or a
`REQUIRED-<name>` value, the ApplicationSet reports `missing input: <name>` and
creates no Application. A value must be non-empty and must not contain `"`,
`\`, `'` or `@`; otherwise the ApplicationSet reports `invalid input: <name>`.

| Input | Meaning |
|---|---|
| `libraryRepoURL`, `libraryRevision` | this repository and the pinned commit; every self-reference |
| `deploymentRepoURL`, `deploymentRevision` | the deployment repository, read for `values/` |
| `catalogRepoURL`, `catalogRevision` | the repository the console's git writer commits models and subscriptions to, and its branch |

Directories whose manifests take inputs (nested ApplicationSets, Policies) are
kustomizations with an `inputs.yaml`. A bare `kustomize build` of one shows
each input as `REQUIRED-<name>`.

## Files a deployment repository holds

Read from `deploymentRepoURL` at `deploymentRevision`:

- `values/cluster-admins.yaml`: `cluster_admins`, the users bound to
  `cluster-admin` on every cluster (`cluster-config`).
  Required by `cluster-config`; `cluster_admins: []` for none.
- `values/grid-bootstrap.yaml`: the grid's enrollment values, at least
  `external.certManager.ca.mode` (`Generate` for a new grid, `Existing` to keep
  a CA). Required by `grid-bootstrap`.
- `values/clusters/<cluster>/rhoai.yaml`: values for one site, optional, such as
  the MaaS gateway hostname prefix
  (`components.aigateway.modelsAsAService.gateway.annotations.ai-grid/maas-gateway-hostname-prefix`,
  `maas` by default).

## Upstream's lab roots

`bootstrap/applicationset.yaml` and `bootstrap/dedicated-hub/` are the roots of
upstream's own lab, and of any fork pointed at itself with
`scripts/set-tenant-repo.sh`. They read every component from this repository and
set every input themselves, to the lab's values, in their generator `values`
and `templatePatch`. This repository is also their deployment repository: they
read the lab's `values/` here (`values/README.md`). A new hub uses this
directory instead.

## Check a deployment

`tests/library/inputs-test.sh` in this repository checks the library itself
with `tests/library/sample-inputs.yaml`. A deployment can run the same checks
against its own values before it pushes.
