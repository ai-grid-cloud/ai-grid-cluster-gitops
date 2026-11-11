# AI Grid component reference

This directory is the reference for the library's components, versioned with the code it describes. Read it at the
library commit your deployment pins.

- [Hub and external dependencies](hub/README.md): the hub's eight items, each with your options, what it requires and
  the lines that select it.
- [Spokes](spokes/README.md): what each site brings and what the hub installs there.
- [Appendix A: inputs and values reference](appendix-a-inputs.md).

## Install AI Grid

The install procedure lives in the deployment template,
[`ai-grid-cloud/ai-grid-deployment-template`](https://github.com/ai-grid-cloud/ai-grid-deployment-template). To install, create your
deployment repository from it with **Use this template** on GitHub, then follow its
[install guide](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/README.md). The guide links
to the pages here at your pinned library commit.

Upstream's own lab, and a fork pointed at itself with `scripts/set-tenant-repo.sh`, install the same components from
this repository's lab roots instead (`bootstrap/applicationset.yaml`, `bootstrap/dedicated-hub/`), with the lab's
inputs and values (`bootstrap/hub/README.md`, "Upstream's lab roots").
