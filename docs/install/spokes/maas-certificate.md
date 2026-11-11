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
| Example chose | A DNS-01 Certificate delivered as its own app; the deployment template's per-site files ([`site-template/`](https://github.com/ai-grid-cloud/ai-grid-deployment-template/tree/main/site-template)) |

## Use ours

Not available: the library has no input for this certificate yet ([known gaps](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/appendix-c-gaps.md)).

## Bring your own

You need a cert-manager ClusterIssuer on each ingress or combined site that issues publicly trusted certificates by
**DNS-01**, or a certificate of your own for each site's MaaS hostname. An HTTP-01 issuer can't solve the challenge
([known issues](#known-issues)). For each such site, add three files to your deployment repository and push them
before you label the site. The deployment template holds them as `site-template/`, laid out at these paths with
`SITE` in place of the site's name.

1. A `Certificate` for the MaaS hostname, as `sites/SITE/maas-tls/certificate.yaml`:

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: maas-gateway-public
     namespace: openshift-ingress
   spec:
     secretName: maas-gateway-public-tls
     dnsNames:
       - HOSTNAME_PREFIX.APPS_DOMAIN
     issuerRef:
       kind: ClusterIssuer
       name: DNS01_ISSUER
   ```

2. An Application that delivers it to the site, as `apps/SITE-maas-tls.yaml`. Your root's own-apps generator picks it
   up. The hub's Argo CD reaches each site through ACM's cluster proxy:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: SITE-maas-tls
     namespace: openshift-gitops
   spec:
     project: default
     source:
       repoURL: '@deploymentRepoURL@'
       targetRevision: '@deploymentRevision@'
       path: sites/SITE/maas-tls
     destination:
       server: https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/SITE
       namespace: openshift-ingress
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

3. The site's values, `values/clusters/SITE/rhoai.yaml`: the MaaS hostname prefix, and the gateway's HTTPS listener
   pointed at the Certificate's Secret. Helm replaces lists whole, so give both of the chart's listeners:

   ```yaml
   components:
     aigateway:
       modelsAsAService:
         gateway:
           annotations:
             ai-grid/maas-gateway-hostname-prefix: HOSTNAME_PREFIX
           spec:
             listeners:
               - name: http
                 port: 80
                 protocol: HTTP
                 allowedRoutes:
                   namespaces:
                     from: Selector
                     selector:
                       matchExpressions:
                         - key: kubernetes.io/metadata.name
                           operator: In
                           values: [openshift-ingress, models-as-a-service, redhat-ai-gateway-infra]
               - name: https
                 port: 443
                 protocol: HTTPS
                 allowedRoutes:
                   namespaces:
                     from: Selector
                     selector:
                       matchExpressions:
                         - key: kubernetes.io/metadata.name
                           operator: In
                           values: [openshift-ingress, models-as-a-service, redhat-ai-gateway-infra]
                 tls:
                   mode: Terminate
                   certificateRefs:
                     - group: ""
                       kind: Secret
                       name: maas-gateway-public-tls
   ```

Replace the following:

- `SITE`: the site's ACM cluster name.
- `HOSTNAME_PREFIX`: the MaaS hostname prefix. With the library's Keycloak, use `maas`
  ([Keycloak](../hub/04-tenant-identity.md#keycloak)).
- `APPS_DOMAIN`: the site's apps domain, as `oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'`
  prints it.
- `DNS01_ISSUER`: your DNS-01 ClusterIssuer on the site.

If you bring a certificate without cert-manager, create Secret `openshift-ingress/maas-gateway-public-tls`
(`kubernetes.io/tls`) on the site, and leave out the Certificate and its Application.

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
