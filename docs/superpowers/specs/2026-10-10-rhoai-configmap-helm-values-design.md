# RHOAI ConfigMap-backed Helm Values Design

## Goal

Allow the RHOAI Helm chart to receive arbitrary, non-confidential values from a Kubernetes ConfigMap while keeping the upstream `odh-gitops` `ai-grid` branch as an automatically tracked Argo CD source.

## Scope

- Add a custom Config Management Plugin (CMP) sidecar for Helm rendering.
- Mount a Kubernetes ConfigMap read-only into the CMP sidecar and use its `values.yaml` key as a Helm values overlay.
- Move the current tracked RHOAI base values into the RHOAI Application's plugin configuration so edits are tracked by the ApplicationSet.
- Keep the nightly CatalogSource rendering with native Helm and its current values reference.
- Do not add AVP to this workflow; the values are non-confidential and come from a ConfigMap.

## Non-goals

- Supplying confidential credentials or other values that must stay out of Argo CD's generated manifests.
- Automatically refreshing the RHOAI Application when the ConfigMap changes.
- Changing the upstream chart branch or RHOAI chart behavior beyond applying the ConfigMap values overlay.

## Architecture

The GitOps configuration Application manages the default `openshift-gitops` Argo CD custom resource and a ConfigMap containing the CMP definition and renderer script. The Argo CD repo server runs the CMP as a sidecar. The sidecar receives the base values from the RHOAI Application's plugin environment and mounts the `rhoai-helm-values` ConfigMap read-only.

The first RHOAI Application source remains the upstream Git chart at `charts/rhai-on-openshift-chart`, tracking `ai-grid`, but uses the custom CMP instead of Argo CD's built-in Helm renderer. The CMP runs `helm template` against the checked-out chart with the base values followed by the mounted ConfigMap overlay. The local values reference and native Helm source for the nightly CatalogSource remain separate sources in the existing multi-source Application.

The renderer uses explicit Helm arguments derived from the Application context and does not pass arbitrary Helm arguments from Application environment values. The upstream chart branch remains visible to Argo CD as a source revision, so branch updates continue to trigger manifest regeneration.

## ConfigMap contract

The cluster administrator manually creates a ConfigMap named `rhoai-helm-values` in namespace `openshift-gitops`. Its `data.values.yaml` entry contains a valid Helm values map. The CMP mounts this key at a fixed, read-only path and supplies it after the tracked base values file so ConfigMap values override matching chart values.

The overlay can contain any values supported by the chart. Helm replaces list values as a whole; an overlay that changes one listener in a list must include the complete list entry and any sibling fields that must remain configured.

The ConfigMap must exist before the CMP sidecar starts. A missing ConfigMap or key prevents the sidecar from starting; invalid YAML/Helm values causes manifest generation to fail, preventing a sync from using incomplete configuration.

## Change and refresh behavior

- Changes to the Application and its base values are tracked through the ApplicationSet Git source.
- Changes to the upstream `ai-grid` branch are tracked as the Application's chart source revision.
- Changes to the manually managed ConfigMap are not a source revision of the RHOAI Application. After changing it, an operator must hard-refresh that Application to regenerate manifests; automated sync can then apply the resulting diff.

## Security boundary

The CMP gets access to the values file through a read-only ConfigMap volume, without Kubernetes API permissions. ConfigMap data and values used by Helm can appear in the cluster and in Argo CD's generated manifests and application state. This design is for non-confidential values such as hostnames; confidential values require a separate secret-management design.

## References

- [OpenShift GitOps 1.20: configuring CMP sidecars in the Argo CD custom resource](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/argo_cd_instance/index)
- [Argo CD: multiple sources for an Application](https://argo-cd.readthedocs.io/en/latest/user-guide/multiple_sources/)
