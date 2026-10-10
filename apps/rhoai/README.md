# RHOAI Helm values

## Argo CD changes

You do not need to register a plugin in the Argo CD UI or edit the Argo CD
instance by hand. This repo manages those changes:

- The existing `apps` ApplicationSet discovers `apps/gitops-cmp/application.yaml`
  and creates the `gitops-cmp` Application.
- [`gitops-cmp`](../gitops-cmp/application.yaml) updates the
  [`ArgoCD/openshift-gitops` resource](../gitops-cmp/manifests/openshift-gitops-argocd.yaml).
  It adds a `helm-configmap-values` sidecar to the repo server and mounts the
  plugin configuration and values ConfigMap into it. OpenShift GitOps rolls
  out the repo-server changes.
- The `rhai-on-openshift` Application selects that plugin for the RHOAI chart.
  The plugin is discovered automatically from the chart's `Chart.yaml`.

The sidecar is configured on the `ArgoCD` custom resource, not in Argo CD's
application settings. OpenShift GitOps supports it under
`spec.repo.sidecarContainers`; that field will not appear in the default
resource until you add it. The configuration in this repo is in
[`openshift-gitops-argocd.yaml`](../gitops-cmp/manifests/openshift-gitops-argocd.yaml).
It adds both the sidecar and the `spec.repo.volumes` mounts it needs.

If applying the setup manually, first create `rhoai-helm-values`, then run
these commands from the repository root while `oc` is pointed at the target
cluster:

```bash
oc apply -f apps/gitops-cmp/manifests/cmp-config.yaml
oc apply -f apps/gitops-cmp/manifests/openshift-gitops-argocd.yaml
```

In the OpenShift console, the equivalent edit is **Operators → Installed
Operators → OpenShift GitOps → Argo CD → openshift-gitops → YAML**. Merge the
`repo.volumes` and `repo.sidecarContainers` entries from the manifest into
the existing `spec.repo` section. Preserve any other repo-server settings or
mounts already on your instance. If the `gitops-cmp` Application is already
managing this resource, make changes in Git and let Argo CD sync them; a
console edit can be reverted by GitOps.

The ApplicationSet reads the repository's remote `HEAD`, so publish these
repo changes to that tracked branch. Before doing so, create the required
`rhoai-helm-values` ConfigMap in `openshift-gitops`. The sidecar's volume is
required; if the ConfigMap is missing, the repo-server pod cannot start.

## Create the values ConfigMap

Keep the overlay in a local `values.yaml` file. Create or update the ConfigMap
with:

```bash
oc create configmap rhoai-helm-values \
  --namespace openshift-gitops \
  --from-file=values.yaml=./values.yaml \
  --dry-run=client -o yaml | oc apply -f -
```

The RHOAI Application layers this manually managed ConfigMap over its tracked
base Helm values. After changing the ConfigMap, wait for Kubernetes to update
the mounted ConfigMap projection. Confirm
`/etc/rhoai-helm-values/values.yaml` in the
`helm-configmap-values` repo-server sidecar contains the new values, then
hard-refresh `rhai-on-openshift` in Argo CD. Review the resulting diff;
automated sync applies it. Updating the ConfigMap does not trigger an Argo CD
refresh by itself.

The overlay can set any non-confidential value supported by the RHOAI chart.
Values can appear in rendered manifests and Argo CD application state, so do
not use the ConfigMap for confidential data.

Helm replaces lists as a whole. To set a listener hostname, include the full
listener entry and the `allowedRoutes` fields that must remain configured. For
example:

```yaml
components:
  kserve:
    gateway:
      spec:
        listeners:
          - name: https
            port: 443
            hostname: inference.apps.example.test
            protocol: HTTPS
            allowedRoutes:
              namespaces:
                from: Selector
                selector:
                  matchExpressions:
                    - key: kubernetes.io/metadata.name
                      operator: In
                      values:
                        - openshift-ingress
```
