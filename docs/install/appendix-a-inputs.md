# Appendix A: inputs and values reference

## Inputs

The 14 inputs, with their meaning, examples and readers, are in [the repositories page, part 4](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/02-repositories.md#4-set-every-input).
Rules: every input is required, non-empty, and free of `"`, `'`, `\` and `@`. The library's `bootstrap/hub/README.md`
documents the same contract for library maintainers.

## Files your deployment repository holds

| File | Required | Read by | Content |
|---|---|---|---|
| `values/cluster-admins.yaml` | Yes | `cluster-config` | `cluster_admins:` list of user names, or `[]` |
| `values/grid-bootstrap.yaml` | Yes | `grid-bootstrap` | `external.certManager.ca.mode` (`Generate` or `Existing`); `managedClusters.createClusterSetBinding` (default `true`) |
| `values/clusters/SITE/rhoai.yaml` | No | `rhoai` | Values for one site, such as `components.aigateway.modelsAsAService.gateway.annotations.ai-grid/maas-gateway-hostname-prefix` (default `maas`) or the gateway's `spec.listeners` |
| `root/kustomization.yaml` | Yes | `deployment-root` | The pin, the selection, the inputs |
| `root/self.yaml` | Yes | `scripts/bootstrap-hub.sh` | Application `deployment-root` |
| `apps/*.yaml` | No | your root's own-apps generator | Your own Applications; they may use `@NAME@` inputs |

## ManagedCluster labels

| Label | Values | Effect |
|---|---|---|
| `ai-grid/enabled` | `true` | Makes the cluster a grid site |
| `ai-grid/role` | `ingress`, `inference`, `combined` | What the site installs; without it nothing installs |
| `location` | Your choice | Shown in the console; model placement can select it |
| `ai-grid/metallb-pool` | `FIRST-LAST` | A MetalLB address range ([load balancers](spokes/networking.md#load-balancers)) *(Unverified.)* |
| `ai-grid/external-services` | `true` | Runs MaaS's shared state on that cluster instead of the hub *(Unverified.)* |
