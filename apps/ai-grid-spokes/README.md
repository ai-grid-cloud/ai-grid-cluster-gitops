# AI Grid spokes

A cluster is an AI Grid spoke when its ManagedCluster carries
`ai-grid/enabled=true` and an `ai-grid/role`, which decides what it runs. A
cluster with no role, or another value, isn't a spoke.

| Role | Runs |
|---|---|
| `ingress` | OpenShift AI with MaaS and the portal, the grid consumer gateway, the tenant Policy, a `maas-db` read replica, the models' MaaS side |
| `inference` | OpenShift AI without MaaS (`apps/rhoai/roles/inference.yaml`), the grid operator and provider gateway, the models |
| `combined` | Both. |

The hub always runs ACM, Argo CD, grid enrollment (`apps/grid-enrollment`) and
the deployment's optional apps. It runs OpenShift AI only if it's labelled as
a spoke too, so a hub without OpenShift AI is `local-cluster` left unlabelled.

```sh
oc label managedcluster site-a ai-grid/enabled=true ai-grid/role=ingress
oc label managedcluster site-a ai-grid/enabled-          # no longer a spoke
```

Removing the label removes the cluster's Applications within about a minute
(their `requeueAfterSeconds`). The generated Applications carry no
resources finalizer, so what they deployed stays on the cluster: removing a
spoke stops managing it, it doesn't uninstall OpenShift AI.

## What this app holds

- Placements `ai-grid-spokes`, `ai-grid-ingress` and `ai-grid-inference` in
  `openshift-gitops`. The ApplicationSets read their decisions live through
  ACM's `acm-placement` ConfigMap (`clusterDecisionResource`), joined with Argo
  CD's cluster Secret for the server address and labels. They never select on
  the Secret's labels alone, because ACM adds and updates those labels but
  never removes one.
- Placements `ai-grid-spokes`, `ai-grid-ingress` and `ai-grid-inference` in
  `ai-grid-policies`, for the Policies there: `ai-grid-ready` and the
  catalog's status Policies (`apps/acm-models`, which also owns the namespace
  and its ClusterSet binding).

Policies in other apps select the same labels: the tenant Policy
(`apps/rhoai/hub/03-tenant-placement.yaml`: the AITenant, the MaaS tenant
config and the grid `ExternalProvider`) and `maas-db`'s credentials go to
ingress and combined spokes, the grid SWIM key to every spoke but the hub.
`rhoai-prerequisites` (with the model namespace and its NetworkPolicies),
Submariner and Argo CD's cluster registration still go to every managed
cluster.
