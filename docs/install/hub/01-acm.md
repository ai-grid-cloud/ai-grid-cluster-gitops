# ACM, the multicluster engine and Submariner

Red Hat Advanced Cluster Management (ACM), with its multicluster engine, is the hub's control plane: it imports the
sites, places components on them by label, and runs the Policies that copy credentials and configuration to them.
Submariner, part of the same component, connects the hub and the sites so the sites reach the hub's shared services.

| | |
|---|---|
| Options | Ours (`apps/acm`) · your existing ACM hub, partly ([bring your own](#bring-your-own)) |
| Example chose | Ours: ACM 2.17.4, with S4 object storage, on AWS load balancers |
| Requires | [Platform services](00-platform-services.md); object storage for ACM observability (S4, ODF or yours); on the hub and every site, a load balancer and two Submariner gateway nodes (cloud or MetalLB) |

## Select it

```yaml
- path: apps/acm/application.yaml
- path: apps/object-storage/s4/application.yaml
```

For object storage, select one of `apps/object-storage/s4/application.yaml` and
`apps/object-storage/odf/application.yaml`, or neither if you bring your own bucket ([object storage](#object-storage)).
For bare-metal sites without a load-balancer provider, also select `- path: apps/metallb/application.yaml`
([site networking](../spokes/networking.md#load-balancers)).

## Red Hat Advanced Cluster Management

ACM is the hub's control plane: it imports the sites, places components on them by label, and runs the Policies that
copy credentials and configuration to them. Almost every other component depends on it; the library's ACM component
also configures the add-ons that the [MaaS database](03-maas-shared-services.md#maas-database), [Limitador's Redis](03-maas-shared-services.md#limitadors-redis), the
provider console and the [observability](07-observability.md) components rely on.

| | |
|---|---|
| Runs on | hub (add-ons run on every managed cluster) |
| Library component | `apps/acm` (select `apps/acm/application.yaml`) |
| Choices | Use ours · Bring your own (partly; see the gaps) |

### Use ours

1. Select `apps/acm/application.yaml` ([select it](#select-it)).

2. Provide object storage for ACM observability before you push: Secret `thanos-object-storage`, key `thanos.yaml`, in
   namespace `open-cluster-management-observability`. Select a library option or bring your own bucket; see
   [Object storage](#object-storage). MultiClusterObservability waits until that Secret exists.
3. Make sure the hub has a default StorageClass. Observability claims a 101 GiB compactor volume and other PVCs without
   naming a class. Run `scripts/check-prerequisites.sh --step hub --context HUB_CONTEXT` from the library checkout.

   Replace `HUB_CONTEXT` with your hub's kubeconfig context.

The component reads only `libraryRepoURL` and `libraryRevision`, and no file from your deployment repository. It
creates the following, in sync-wave order:

| What | Details |
|---|---|
| Operator | Subscription `acm-operator-subscription`, package `advanced-cluster-management`, channel `release-2.17`, automatic approval, in `open-cluster-management` |
| `MultiClusterHub` | `multiclusterhub`, default spec |
| Governance add-ons | ClusterManagementAddOns `governance-policy-framework`, `config-policy-controller` and `governance-standalone-hub-templating`, installed on every cluster in ManagedClusterSet `global` through Placement `policy-addons-clusters` |
| Search collector | Policy `search-collector` creates the `search-collector` add-on on every managed cluster except the hub and clusters that have a `KlusterletAddonConfig`. The console's backend reads a site's GPUs and MaaS subscriptions through Search. |
| Observability | `MultiClusterObservability` `observability`: size `minimal`, 2 receive replicas, 7-day raw and 14-day downsampled retention, platform and user-workload metrics |
| Submariner | `Broker` in `default-broker` with Globalnet, and ApplicationSet `acm-submariner`, which installs the Submariner add-on on every cluster registered in Argo CD, the hub included; see [Submariner](#submariner) |

[Submariner](#submariner) covers the gateway nodes and ports each site and the hub need.

#### Verify

```sh
oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath='{.status.currentVersion} {.status.phase}{"\n"}'
oc get multiclusterobservability observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get policy search-collector -n open-cluster-management -o jsonpath='{.status.compliant}{"\n"}'
oc get managedclusteraddon -A | grep -E 'search-collector|submariner'
oc get applications.argoproj.io -n openshift-gitops | grep acm
```

You should see `2.17.x Running`, `True`, `Compliant`, one `search-collector` add-on per site, one `submariner` add-on
per cluster, and Applications `acm` and `acm-submariner-<cluster>` Synced and Healthy. Until the first site joins,
`acm-submariner-local-cluster` stays unhealthy ([Submariner](#known-issues-1)). This is expected.

### Bring your own

If your hub already runs ACM, the library expects:

- ACM 2.17. The install was verified on ACM 2.17.4; other versions are untested.
- ManagedClusterSet `global` (ACM creates it by default). Components bind it in their own namespaces.
- Argo CD integration through `GitOpsCluster` (the library's `apps/argo-registration` creates it).
- Hub templating on managed clusters (`governance-standalone-hub-templating`), the search collector on every site,
  MultiClusterObservability reading `thanos-object-storage`, and the Submariner broker with Globalnet and the add-on on
  every cluster.

The library has no input to skip only the operator and `MultiClusterHub` while keeping the add-on configuration, so
leaving `apps/acm` out also leaves out the add-ons in the list. Create the equivalents yourself from
[`apps/acm/manifests`](../../../apps/acm/manifests) and [`apps/acm/submariner`](../../../apps/acm/submariner).
Selecting `apps/acm` on a hub where ACM is already installed under a different Subscription name is untested. See
[Gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md). *(Unverified.)*

Check that your ACM version and add-ons match:

```sh
oc get multiclusterhub -A -o jsonpath='{.items[0].status.currentVersion}{"\n"}'
oc get clustermanagementaddon governance-standalone-hub-templating search-collector submariner
oc get managedclusterset global
```

### Skip

You can't skip ACM. Without it no site joins, and nothing reaches the sites.

### Upgrade

The operator channel is fixed in the library at `release-2.17` with automatic install-plan approval, so z-stream
updates install as Red Hat publishes them. A new minor version comes with a library pin that changes the channel.

### Known issues

Submariner's known issues are in [Submariner](#known-issues-1).

## Submariner

Submariner connects the hub and the sites so the sites reach the hub's grid enrollment, MaaS database primary and Redis
through `*.svc.clusterset.local` names. The [MaaS database](03-maas-shared-services.md#maas-database) replicas and the
[rate-limit counters](03-maas-shared-services.md#limitadors-redis) depend on it.

| | |
|---|---|
| Runs on | hub and every site |
| Library component | Part of `apps/acm`: selecting [ACM](#red-hat-advanced-cluster-management) installs it. There's no separate component to select. |
| Choices | Use ours. Bring your own only with your own ACM ([ACM](#bring-your-own)). |

### Use ours

[ACM](#red-hat-advanced-cluster-management)'s component creates a `Broker` in `default-broker` with Globalnet (`242.0.0.0/8`), and ApplicationSet
`acm-submariner`, which installs the Submariner add-on with 2 gateways behind a LoadBalancer Service on every cluster
registered in Argo CD, the hub included. The add-on's settings are in
[`apps/acm/submariner`](../../../apps/acm/submariner).

On each site, and on the hub:

1. Make sure two nodes can act as gateways (the component asks for `gateways: 2`). The
   [`cluster-config`](00-platform-services.md#cluster-sign-in-and-admins) Policy `submariner-gateway-nodes` labels `submariner.io/gateway=true` only
   on nodes whose only role is `worker`. Compact clusters, where every node is also a control-plane node, and
   single-node OpenShift get no gateway node from it, so you label them by hand. Check which nodes carry the gateway
   label:

   ```sh
   oc --context CLUSTER_CONTEXT get nodes -l submariner.io/gateway=true
   ```

   If none are listed after the add-on installs, label two nodes by hand. *(Unverified.)*

   ```sh
   oc --context CLUSTER_CONTEXT label node NODE_NAME submariner.io/gateway=true
   ```

2. Give the gateways a load balancer. On a cloud, the provider creates it; on bare metal, you need MetalLB
   ([load balancers](../spokes/networking.md#load-balancers)).
3. Allow the Submariner tunnel traffic to the gateways' load balancer: UDP 4500 (IPsec NAT traversal) and UDP 4490
   (NAT discovery), from every other cluster in the grid. ACM can't open cloud ports for you unless it has cloud
   credentials for the cluster. *(Unverified.)*

Replace `CLUSTER_CONTEXT` with the kubeconfig context of the site or hub, and `NODE_NAME` with a node's name.

#### Verify

```sh
oc get managedclusteraddon -A | grep submariner
oc get applications.argoproj.io -n openshift-gitops | grep acm-submariner
oc --context CLUSTER_CONTEXT -n submariner-operator get svc --field-selector spec.type=LoadBalancer
```

You should see one `submariner` add-on per cluster, Applications `acm-submariner-<cluster>` Synced and Healthy, and an
`EXTERNAL-IP` on the gateway Service. Until the first site joins, `acm-submariner-local-cluster` stays unhealthy: the
hub's gateway has no peer to connect to. This is expected.

### Bring your own

If you leave `apps/acm` out, you also leave out its Submariner configuration. Create the broker with Globalnet and the
add-on on every cluster yourself, from [`apps/acm/submariner`](../../../apps/acm/submariner). See
[ACM](#bring-your-own). *(Unverified.)*

### Skip

You can't skip it. Without it, the sites can't reach the hub's MaaS database primary or Redis.

### Upgrade

The add-on's settings move with the library pin; the Submariner version follows ACM's.

### Known issues

- **Symptom:** `acm-submariner-<cluster>`, `limitador-redis` and the `maas-db` ServiceExport are unhealthy on a new hub.
  **Cause:** Submariner has no gateway connection, and no global IP to export, until a site joins.
  **Workaround:** None needed. They turn Healthy after the first site joins.
- **Symptom:** After you remove a site's AI Grid labels, `acm-submariner-<cluster>` stays.
  **Cause:** Submariner goes to every cluster registered in Argo CD, not only AI Grid sites.
  **Workaround:** It goes when you detach the ManagedCluster.
- **Symptom:** No `submariner.io/gateway=true` node on a compact cluster or single-node OpenShift, and the gateway
  never connects.
  **Cause:** The `submariner-gateway-nodes` Policy labels only nodes whose only role is `worker`.
  **Workaround:** Label the gateway nodes by hand, as in the first step of [Use ours](#use-ours-1).

## Object storage

ACM observability (Thanos) on the hub stores the fleet's metrics in an S3 bucket. The library treats the bucket as
infrastructure behind a contract, a Secret that [ACM](#red-hat-advanced-cluster-management)'s MultiClusterObservability reads; the provider
console's monitoring pages depend on it.

| | |
|---|---|
| Runs on | hub |
| Library component | `apps/object-storage/s4` (select `apps/object-storage/s4/application.yaml`) or `apps/object-storage/odf` (select `apps/object-storage/odf/application.yaml`) |
| Choices | Use ours (S4 or ODF) · Bring your own S3 |

Select at most one option. The [README](../../../apps/object-storage/README.md) has the details.

### The contract

- Secret `thanos-object-storage` in namespace `open-cluster-management-observability`.
- Key `thanos.yaml`: a [Thanos object-store configuration](https://thanos.io/tip/thanos/storage.md/) of
  `type: s3`, with `bucket`, `endpoint`, `insecure`, `access_key` and `secret_key`.
- The bucket exists.

MultiClusterObservability `observability` waits until the Secret exists.

### Use ours

#### S4

S4 is one S3 server pod (Ceph RGW, `quay.io/rh-aiservices-bu/s4`) on a 50 GiB PVC in the observability namespace.
It's a single replica: use it for demos and tests, not production. The verified install used S4.

1. Add both lines to the `files` list in your `root/kustomization.yaml`. S4 needs
   [External Secrets](00-platform-services.md#external-secrets-operator) to generate its keys:

   ```yaml
   - path: apps/external-secrets/application.yaml
   - path: apps/object-storage/s4/application.yaml
   ```

2. Make sure the hub has a default StorageClass.

It reads the `libraryRepoURL` and `libraryRevision` inputs and no file from your deployment repository. You create no
Secret: two external-secrets `Password` generators create the S3 keys once on the hub, and ExternalSecret
`thanos-object-storage` writes `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `thanos.yaml` into the contract
Secret (`refreshPolicy: CreatedOnce`, `deletionPolicy: Retain`). Argo CD also creates PVC `s4-data`, Deployment and
Service `s4` (port `7480`, in-cluster only), a NetworkPolicy that admits only the observability namespace, and a Sync
hook Job `thanos-bucket` that creates bucket `thanos`. The Application never prunes, so deleting a file doesn't delete
stored metrics.

#### ODF

The ODF option uses the Multicloud Object Gateway of OpenShift Data Foundation. *(Unverified.)*

1. Select the option, and ODF itself unless the hub already runs it with NooBaa:

   ```yaml
   - path: apps/object-storage/odf/application.yaml
   ```

   To have the library install ODF, keep the root's second generator (the ODF generator, `apps/odf/application.yaml`)
   with its `repoURL`, `revision` and `values` patched like the first one. Otherwise remove it, as the example
   deployment does (`- { op: remove, path: /spec/generators/1 }`). The ODF generator waits for the hub's
   `openshiftVersion-major-minor` label and picks the ODF channel `stable-<version>` from it. If
   `openshift-storage` already has an OperatorGroup, label the hub's ManagedCluster
   `ai-grid/odf-operatorgroup=existing`.

2. Argo CD creates ObjectBucketClaim `acm-observability-thanos` (StorageClass `openshift-storage.noobaa.io`) and a Job
   that renders the claim's bucket and keys into the contract Secret.

#### Verify

```sh
oc -n open-cluster-management-observability get secret thanos-object-storage \
  -o go-template='{{if index .data "thanos.yaml"}}thanos.yaml present{{"\n"}}{{end}}'
oc -n open-cluster-management-observability get pods -l app=s4
oc get multiclusterobservability observability \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

You should see `thanos.yaml present`, the `s4` pod `Running` (S4 only), and `True`. The hub prerequisites check also
reports `OK` for `object storage`.

### Bring your own

Use any S3-compatible store your hub can reach. *(Unverified.)*

1. Create the bucket in your store.
2. Before ACM observability starts, create the contract Secret on the hub, from your vault with an ExternalSecret, or
   by hand from a local file you then delete:

   ```sh
   oc create namespace open-cluster-management-observability --dry-run=client -o yaml | oc apply -f -
   oc -n open-cluster-management-observability create secret generic thanos-object-storage \
     --from-file=thanos.yaml=THANOS_YAML_FILE
   ```

   Replace `THANOS_YAML_FILE` with the path of a file with this content:

   ```yaml
   type: s3
   config:
     bucket: BUCKET
     endpoint: HOST:PORT
     insecure: false
     access_key: ACCESS_KEY
     secret_key: SECRET_KEY
   ```

   Replace `BUCKET`, `HOST:PORT`, `ACCESS_KEY` and `SECRET_KEY` with your store's values. Never commit them.

3. Select neither `apps/object-storage/s4` nor `apps/object-storage/odf`.

Check it with the verify commands, and with the prerequisites check:

```sh
scripts/check-prerequisites.sh --step hub --context HUB_CONTEXT
```

Replace `HUB_CONTEXT` with your hub's kubeconfig context.

### Skip

You can't skip it while you select `apps/acm`: MultiClusterObservability waits for the Secret, so the hub collects no
metrics and the console's monitoring pages stay empty.

### Upgrade

Each option moves with the library pin with no manual step. Neither option prunes, and S4's keys never change after
the first sync, because S4 creates its user from them on first start. Switching options doesn't move stored metrics.

### Known issues

- **Symptom:** You can't select the usage-log stack (`apps/ai-grid-o11y`, `apps/ai-grid-usage-logs`) with S4 or your
  own S3.
  **Cause:** Loki claims its own ODF bucket; it has no object-storage input yet ([gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).
  **Workaround:** Leave the usage-log components out, as the example deployment does, or run ODF.
