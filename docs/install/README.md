# AI Grid component reference

This directory is the reference for the library's components, versioned with the code it describes. Read it at the
library commit your deployment pins.

## How AI Grid works

AI Grid serves models from many OpenShift clusters as one service. Tenants call one endpoint, Models-as-a-Service
(MaaS) checks their identity and subscription, and the grid routes each request to a site that runs the model. A hub
cluster runs Red Hat Advanced Cluster Management (ACM), Argo CD and the provider console, and delivers everything else
to the sites.

```text
                tenants (OIDC tokens or API keys)
                              |
                              v
   +---------------- ingress site ----------------+       +---- inference site ----+
   | MaaS gateway, Org UI, grid consumer gateway  | mTLS  | grid provider gateway, |
   | (a combined site is ingress + inference)     |------>| models                 |
   +----------------------------------------------+       +------------------------+
                  ^                                                  ^
                  |  ACM policies, Argo CD applications, Submariner  |
                  +---------------------- hub -----------------------+
        ACM, Argo CD, grid enrollment, site and model delivery, provider console,
        MaaS database and Redis, tenant identity provider
```

The hub's Argo CD reads three repositories: the **library** (this repository: the components, pinned at one commit),
your **deployment repository** (which components run, the inputs, each site's files), and your **catalog repository**
(models and subscriptions, written by the provider console).

- [Hub and external dependencies](hub/README.md): the hub's eight items, each with your options, what it requires and
  the lines that select it.
- [Spokes](spokes/README.md): what each site brings and what the hub installs there.
- [Appendix A: inputs and values reference](appendix-a-inputs.md).
- [Operate](operate.md): upgrade, add and remove sites, rotate credentials, uninstall.
- [Tenant access](tenant-access.md): API keys, refusal checks, revoking a key.
- [Troubleshooting after install](troubleshooting.md).
- [Known gaps](known-gaps.md): what this release of the library doesn't do yet.

## Install AI Grid

The install procedure lives in the deployment template,
[`ai-grid-cloud/ai-grid-deployment-template`](https://github.com/ai-grid-cloud/ai-grid-deployment-template). To install, create your
deployment repository from it with **Use this template** on GitHub, then follow its
[install guide](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/README.md). The guide links
to the pages here at your pinned library commit.

Upstream's own lab, and a fork pointed at itself with `scripts/set-tenant-repo.sh`, install the same components from
this repository's lab roots instead (`bootstrap/applicationset.yaml`, `bootstrap/dedicated-hub/`), with the lab's
inputs and values (`bootstrap/hub/README.md`, "Upstream's lab roots").
