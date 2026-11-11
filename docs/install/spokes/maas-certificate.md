# MaaS gateway certificate

Tenants call each ingress or combined site's MaaS gateway at `https://HOSTNAME_PREFIX.APPS_DOMAIN`, so the gateway
needs a certificate your tenants trust. Without one, the gateway presents its in-cluster service certificate and
tenants' TLS clients reject it. [OpenShift AI](openshift-ai.md#openshift-ai-with-maas) creates the gateway; [cert-manager](../hub/00-platform-services.md#cert-manager) is
the usual way to issue its certificate.

| | |
|---|---|
| Runs on | ingress and combined sites |
| Library component | None yet: a values override in `values/clusters/SITE/rhoai.yaml` plus your own `Certificate` |
| Choices | Bring your own: a DNS-01 ClusterIssuer on the site, or your own certificate. Use ours isn't available yet. |
| Example chose | A DNS-01 Certificate delivered as its own app ([`apps/site-b-maas-tls.yaml`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/apps/site-b-maas-tls.yaml)) |

## Use ours

Not available: the library has no input for this certificate yet ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).

## Bring your own

You need a cert-manager ClusterIssuer on each ingress or combined site that issues publicly trusted certificates by
**DNS-01**, or a certificate of your own for each site's MaaS hostname
([before you start](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/01-before-you-start.md#3-accounts-and-credentials)). On each such site:

1. Add a `Certificate` in namespace `openshift-ingress` for `HOSTNAME_PREFIX.APPS_DOMAIN`, with
   `secretName: maas-gateway-public-tls`, to your deployment repository.
2. Add an Application of your own that delivers it to the site. Your root's own-apps generator picks it up.
3. Point the gateway's HTTPS listener at the Secret in `values/clusters/SITE/rhoai.yaml`. Helm replaces lists whole, so
   give both of the chart's listeners.

The templates for all three are in [join each site to the grid, part 1](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/06-join-grid.md#1-add-the-sites-values); the example deployment's
versions are [`apps/site-b-maas-tls.yaml`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/apps/site-b-maas-tls.yaml),
[`sites/site-b/maas-tls/certificate.yaml`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/sites/site-b/maas-tls/certificate.yaml)
and [`values/clusters/site-b/rhoai.yaml`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/values/clusters/site-b/rhoai.yaml).

If you bring a certificate without cert-manager, create Secret `openshift-ingress/maas-gateway-public-tls`
(`kubernetes.io/tls`) on the site and skip the Certificate and its Application.

Use a certificate of its own for the MaaS hostname, not the router's wildcard, so browsers don't reuse one connection
across hosts.

### Verify

```sh
oc --context SITE_CONTEXT get certificate maas-gateway-public -n openshift-ingress
```

Replace `SITE_CONTEXT` with the site's kubeconfig context. Run it after the site is labelled.

You should see the Certificate `READY` `True`.

## Skip

You can't skip it: without a trusted certificate, tenants get a certificate error on every call.

## Upgrade

Your Certificate renews through cert-manager on its own schedule. A library pin that changes the chart's gateway
listeners needs the same change in your listener override, because your override replaces the chart's list.

## Known issues

- **Symptom:** Tenants calling `https://HOSTNAME_PREFIX.APPS_DOMAIN` get a certificate error.
  **Cause:** The OpenShift AI chart terminates TLS on the MaaS gateway's HTTPS listener with a service CA certificate.
  **Workaround:** Bring your own certificate, as this page describes.
- **Symptom:** A router Route in front of the gateway doesn't help, and an HTTP-01 certificate never issues.
  **Cause:** OpenShift points the gateway's hostname at the gateway's own load balancer, not the router, so a Route
  can't front it and an HTTP-01 issuer can't solve the challenge through the gateway.
  **Workaround:** Use a DNS-01 ClusterIssuer, or a certificate you issue elsewhere.
- **Symptom:** MaaS answers on `http://HOSTNAME_PREFIX.APPS_DOMAIN` (port 80) in cleartext.
  **Cause:** The chart's default `http` listener serves the same routes as HTTPS.
  **Workaround:** None in the library yet. If you override the listeners, you can drop or restrict the `http` one, or
  block port 80 at your load balancer or network. *(Unverified.)*
