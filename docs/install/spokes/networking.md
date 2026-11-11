# Site networking

Each site needs a load balancer, two nodes for Submariner's gateways, and DNS that answers `AAAA` queries. The hub
needs the same load balancer and gateway nodes for its own Submariner gateway.

## Load balancers

Several AI Grid Services are of type `LoadBalancer`, so each cluster needs a load-balancer provider: your cloud's, or
MetalLB on bare metal. The MaaS gateway that tenants call, the serving gateway where models run, and Submariner's
cross-cluster gateways depend on it.

| | |
|---|---|
| Runs on | hub (Submariner); ingress, inference and combined sites |
| Library component | Cloud: none, infrastructure you provide. Bare metal: `apps/metallb` (select `apps/metallb/application.yaml`) |
| Choices | Bring your own (cloud or existing) · Use ours (MetalLB) |

### What needs a load balancer

| Service | Where | Created by |
|---|---|---|
| MaaS gateway `maas-default-gateway` | ingress and combined sites | OpenShift's Gateway API controller, in `openshift-ingress`; tenants call its hostname |
| Serving gateway `openshift-ai-inference` | inference and combined sites | The same controller, in `openshift-ingress` |
| Submariner gateways | every managed cluster, the hub included | ACM's Submariner add-on (`loadBalancerEnable: true` in `apps/acm/submariner/values.yaml`) |

The grid's own gateways don't need one: the consumer and provider gateways are `ClusterIP` Services, and peers reach
the provider gateway through a passthrough Route on the default router, port 443.

### Bring your own

On AWS, the cloud provider creates the load balancers with no configuration; that's the verified path. Other clouds
and an existing MetalLB or BGP setup work the same way if they give a `LoadBalancer` Service an address. *(Unverified
beyond AWS.)*

The contract:

- Every `LoadBalancer` Service in `openshift-ingress` and `submariner-operator` gets an address.
- Tenants can reach the MaaS gateway's address on port 443. OpenShift publishes the gateway's hostname through a
  DNSRecord that points at this address, not at the router.
- The sites can reach each other's Submariner gateway addresses on Submariner's tunnel ports.

Check a site:

```sh
oc --context SITE_CONTEXT -n openshift-ingress get svc --field-selector spec.type=LoadBalancer
oc --context SITE_CONTEXT -n submariner-operator get svc --field-selector spec.type=LoadBalancer
oc --context SITE_CONTEXT -n openshift-ingress get gateway
```

Replace `SITE_CONTEXT` with your kubeconfig context for the site.

You should see an `EXTERNAL-IP` (an address or hostname) on every Service, not `<pending>`, and each Gateway
`PROGRAMMED` `True`.

If a site has no load balancer for Submariner, `loadBalancerEnable` must be `false` before the hub's first sync, and
the gateway nodes must be reachable from the other sites on their own addresses. That value is in the library, not in
your deployment repository, so changing it today means changing the library ([gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).
*(Unverified.)*

### Use ours

MetalLB is for bare-metal sites without a load-balancer provider. *(Unverified: the verified install ran on AWS
without MetalLB.)* The [README](../../../apps/metallb/README.md) has the details.

1. Select `apps/metallb/application.yaml` ([select it](../hub/01-acm.md#select-it)).

   It reads the `libraryRepoURL` and `libraryRevision` inputs. It creates ApplicationSet `metallb` on the hub, which
   does nothing until a cluster is labelled.

2. Label each site that needs MetalLB with its L2 address range, an IPv4 `FIRST-LAST` range inside the site's network
   and outside the addresses the installer and the nodes use:

   ```sh
   oc label managedcluster CLUSTER ai-grid/metallb-pool=FIRST-LAST
   ```

   Replace `CLUSTER` with the ManagedCluster name, and `FIRST-LAST` with the range, such as
   `192.0.2.10-192.0.2.50`.

Argo CD then installs, on that cluster, namespace `metallb-system`, the MetalLB operator (channel `stable`), a
`MetalLB` instance, IPAddressPool `ai-grid` with the label's range, and an L2Advertisement. A cluster without the label
gets nothing. An invalid range fails the render and applies nothing.

#### Verify

```sh
oc --context SITE_CONTEXT -n metallb-system get ipaddresspool,l2advertisement
oc --context SITE_CONTEXT -n openshift-ingress get svc --field-selector spec.type=LoadBalancer
```

You should see pool `ai-grid` and an address from it on each `LoadBalancer` Service.

### Skip

You can't skip it. Without an address, the MaaS gateway is unreachable on an ingress or combined site, and Submariner
can't connect the sites, so the shared MaaS database and rate-limit counters don't work.

### Upgrade

MetalLB's chart moves with the library pin. The operator follows its Subscription. The namespace, OperatorGroup,
Subscription and `MetalLB` instance are never pruned; removing the label keeps everything it created, pools included.
Removing MetalLB from a site is a manual step.

### Known issues

- **Symptom:** About one call in six to the MaaS gateway hangs and fails the TLS handshake.
  **Cause:** The gateway's load balancer has an address in each availability zone, and one zone has no gateway pod
  behind it (inferred on AWS).
  **Workaround:** This is infrastructure. Check each address the hostname resolves to, for example with
  `curl --resolve`, and make sure every zone that the load balancer spans has a gateway pod, or enable cross-zone
  load balancing for it. *(Unverified.)*
- **Symptom:** A site needs more than one pool, or already runs the MetalLB operator, and your deployment repository
  has nowhere to say so.
  **Cause:** The MetalLB ApplicationSet reads per-site overrides (`apps/metallb/values-CLUSTER.yaml`) from the library,
  not from your deployment repository ([gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).
  **Workaround:** Use one range per site through the label, or install MetalLB yourself and leave `apps/metallb` out.

## Submariner gateways

Every cluster, the hub included, runs two Submariner gateways behind a LoadBalancer Service. On each site:

- Two nodes can act as gateways. `cluster-config` labels worker-only nodes; on compact clusters and single-node
  OpenShift you label them by hand.
- Every other cluster in the grid can reach the gateways' load balancer on UDP 4500 and 4490.

The steps and checks are in [Submariner](../hub/01-acm.md#submariner).

## DNS

- Each ingress or combined site's MaaS hostname, `PREFIX.apps.CLUSTER_DOMAIN`, resolves to the MaaS gateway's load
  balancer. OpenShift creates this record.
- Every router name answers `AAAA` queries with an address or an empty answer, never `NXDOMAIN`. Check with
  `dig AAAA router-default.apps.CLUSTER_DOMAIN`. An `NXDOMAIN` answer leaves every GridSite `Connecting`.
