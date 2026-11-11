# Grid bootstrap, enrollment and status policies

The grid's hub side has two parts: grid bootstrap and enrollment, which create the grid and enrol each site, and the
status policies, which report each site's state back to the hub for the provider console.

| | |
|---|---|
| Options | No choice. You can bring the grid's CA ([bring your own](#bring-your-own)), and skip the status policies only without the console ([skip](#skip-1)). |
| Example chose | Ours: a new grid with a new CA (`Generate`) |
| Requires | cert-manager ([platform services](00-platform-services.md#cert-manager)); [ACM](01-acm.md); the site Placements from [site delivery](06-site-delivery.md) |

## Select it

```yaml
- path: apps/grid-bootstrap/application.yaml
- path: apps/ai-grid-policies/application.yaml
```

Also add `values/grid-bootstrap.yaml` to your deployment repository
([fill in the values files](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/02-repositories.md#5-fill-in-the-values-files)).

## Grid bootstrap

This component creates the grid on the hub: its persistent grid ID, its certificate authority, and the enrollment
that gives each labelled cluster a site identity certificate and its `GridNetwork` through ACM. The grid operator on
every site, and so all cross-site routing, depends on it.

| | |
|---|---|
| Runs on | hub (CA, Certificates, Policies); delivers to ingress, inference and combined sites |
| Library component | `apps/grid-bootstrap` (select `apps/grid-bootstrap/application.yaml`) |
| Choices | Use ours. Bring your own: only the CA (mode `Existing`). Skip isn't an option. |

### Use ours

1. Select `apps/grid-bootstrap/application.yaml` ([select it](#select-it)).

   It reads the inputs `libraryRepoURL`, `libraryRevision`, `deploymentRepoURL` and `deploymentRevision`. It installs
   the `grid-enrollment` chart from `opendatahub-io/odh-gitops` `main`, in external mode, with
   cert-manager. cert-manager must already run on the hub.

2. Add `values/grid-bootstrap.yaml` to your deployment repository. For a new grid:

   ```yaml
   external:
     certManager:
       ca:
         mode: Generate
   ```

   The file is required. `Generate` creates the CA once, in Secret `redhat-ai-grid/grid-ca-key`; bootstrap never
   regenerates it. For another mode, see [Bring your own](#bring-your-own).

   The library's `apps/grid-bootstrap/values.yaml` sets the rest, including
   `managedClusters.createClusterSetBinding: true`: this release owns ManagedClusterSetBinding
   `redhat-ai-grid/global`, which the grid's Placements select through. The root ApplicationSet removes the copy that
   `apps/rhoai` carries, so exactly one Application owns it.

Argo CD then creates, in namespace `redhat-ai-grid` on the hub:

- the CA Issuer `grid-ca` and the immutable ConfigMap `grid-bootstrap-state`, which holds the grid ID;
- one site identity `Certificate` per cluster labelled `ai-grid/enabled=true`, with its Secret `grid-site-SITE`
  (`SITE` is the ManagedCluster name, which is also the site's grid identity);
- Policies that deliver to each site its identity Secret `grid-site-identity`, the public CA bundle, and the complete
  `GridNetwork` (Local membership, poll transport, SPIFFE trust);
- a read-only GridSite observer per site, which distributes each site's public endpoints to its peers;
- the library's extra Policies (`apps/grid-bootstrap/policies`): the operator's config RBAC, the CRD hand-back, and
  the local-endpoints Policy that publishes the signals Route on inference and combined sites.

The CA's signing key never leaves the hub. The [README](../../../apps/grid-bootstrap/README.md) covers rollback and
recovery; read it before you change the CA or the network.

#### Verify

On the hub:

```sh
oc -n redhat-ai-grid get managedclustersetbinding global
oc -n redhat-ai-grid get issuers.cert-manager.io grid-ca
oc -n redhat-ai-grid get certificates.cert-manager.io
oc -n redhat-ai-grid get configmap grid-bootstrap-state
oc -n redhat-ai-grid get policies
```

You should see one binding `global`, the Issuer `Ready`, one `Ready` Certificate per labelled site, and every Policy
`Compliant`.

On each site:

```sh
oc get gridnetworks.grid.praxis.fast,gridsites.grid.praxis.fast -A
oc -n redhat-ai-grid get secret grid-site-identity \
  -o custom-columns='NAME:.metadata.name,CERT:.metadata.annotations.cert-manager\.io/certificate-name'
```

You should see the `GridNetwork` `grid` and a `GridSite` for the site that is `Available`; on more than one site,
each site also lists its peers. Every site shows the same grid ID.

### Bring your own

You can't replace enrollment, but you can bring the grid's CA. To keep the CA of an existing grid, or to use one your
PKI issued, set the mode to `Existing` in `values/grid-bootstrap.yaml` and create the CA Secret on the hub first:

```sh
oc -n redhat-ai-grid create secret tls grid-ca-key --cert=CA_CERT_FILE --key=CA_KEY_FILE
```

Replace the following:

- `CA_CERT_FILE`: the PEM file of a CA certificate (`CA:TRUE`).
- `CA_KEY_FILE`: its private key.

`Existing` never writes the CA Secret. To use another Secret name, set `external.certManager.ca.secretName` too.
*(Unverified.)*

### Skip

You can't skip it. Without it, no site gets an identity or a `GridNetwork`, and the grid operator routes nothing
between sites.

### Upgrade

The chart's commit and the enrollment image digest are pinned in the library, so they move with the library pin, with
no manual step. The grid ID and the CA persist across upgrades. Never switch the CA mode to `Generate` as a recovery
step, and never delete the `GridNetwork` or `grid-bootstrap-state` to roll back.

### Known issues

**Symptom:** the grid's invite Placements select no cluster and no site gets a `GridNetwork`.
**Cause:** no ManagedClusterSetBinding `redhat-ai-grid/global` exists: `createClusterSetBinding` is `false`, for
example in an override of `managedClusters` in `values/grid-bootstrap.yaml` that leaves it out.
**Workaround:** set `createClusterSetBinding: true` (the library's default), and keep that setting if you override
`managedClusters`.

## AI Grid Policies

This component creates the inform-only ACM Policies that report each site's state back to the hub: whether the site
is provisioned, and whether the catalog's models and subscriptions came up. The [provider console](05-console-and-model-delivery.md#provider-console)
reads them to show a cluster as Provisioning or Provisioned and a model or subscription as ready.

| | |
|---|---|
| Runs on | hub (Policies); evaluated on ingress, inference and combined sites |
| Library component | `apps/ai-grid-policies` (select `apps/ai-grid-policies/application.yaml`) |
| Choices | Use ours. Bring your own and Skip aren't options when you run the console. |

### Use ours

1. Select `apps/ai-grid-policies/application.yaml` ([select it](#select-it)).

   It reads the inputs `libraryRepoURL` and `libraryRevision`, and no file from your deployment repository. It binds
   its Policies to the Placements that [spoke delivery](06-site-delivery.md#spoke-delivery) creates in the same namespace, so select
   `apps/ai-grid-spokes` too.

Argo CD creates namespace `ai-grid-policies` on the hub, a `global` ManagedClusterSetBinding there, and three
Policies. All three are `inform`: they change nothing on a site.

| Policy | Placed on | Compliant when |
|---|---|---|
| `ai-grid-ready` | every AI Grid site (`ai-grid-spokes`) | The site's DataScienceCluster `default-dsc` reports `AIGridReady=True` and the role's KServe state (`KserveReady=False` on ingress, `True` on inference and combined), and Deployment `redhat-ai-grid/grid-operator` is `Available` |
| `ai-grid-models-status` | inference and combined sites (`ai-grid-inference`) | Every LLMInferenceService in `ai-grid-internal-models` is `Ready` |
| `ai-grid-catalog-status` | ingress and combined sites (`ai-grid-ingress`) | Every ExternalModel and MaaSModelRef in `models-as-a-service` is `Ready`, and every MaaSSubscription and MaaSAuthPolicy there is `Active` |

The status Policies look up every object of a kind, so they need no change when the catalog changes, and a namespace
with no such objects is `Compliant`. The console's backend reads the per-site copies (namespace `SITE`, name
`ai-grid-policies.POLICY`). Those namespace, Policy and ConfigurationPolicy names are the backend's contract: don't
rename them.

The tenant settings (the AITenant and its OIDC client) aren't here: [OpenShift AI](../spokes/openshift-ai.md#openshift-ai-with-maas) delivers them with
Policy `redhat-ai-grid/rhoai-ingress-clusters`.

#### Verify

On the hub:

```sh
oc -n ai-grid-policies get policies
oc -n SITE get policies | grep ai-grid-policies
```

Replace `SITE` with a site's ManagedCluster name.

You should see the three Policies. `ai-grid-ready` turns `Compliant` for a site once OpenShift AI and the grid
operator are up there, 45 to 60 minutes after you label it. The two status Policies are `Compliant` on a site with an
empty catalog, and turn `NonCompliant` while a new model or subscription is coming up.

To see which objects a status Policy found, read its message:

```sh
oc -n SITE get policy ai-grid-policies.ai-grid-catalog-status \
  -o jsonpath='{range .status.details[*].history[0]}{.message}{"\n"}{end}'
```

You should see lines such as `maassubscriptions [...] found as specified in namespace models-as-a-service`.

### Bring your own

Not an option while you run the provider console: its backend reads these Policies by name. Without the console, the
Policies are only a convenience; your own monitoring can check the same conditions.

### Skip

You can skip it only if you don't select the [provider console](05-console-and-model-delivery.md#provider-console). With the console and without this
component, the console shows every cluster as Provisioning and no model or subscription status. *(Unverified.)*

### Upgrade

The component moves with the library pin and needs no manual step.
