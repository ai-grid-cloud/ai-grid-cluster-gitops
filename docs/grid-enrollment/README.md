# Grid enrollment on the hub

The enrollment service signs site identities from the grid CA. It runs on
`local-cluster` only; `grid-enrollment.enabled` is set per cluster by the rhoai
ApplicationSet.

## Reaching it from a spoke

Sites reach enrollment through a passthrough Route, not the clusterset name.
ACM's Submariner addon refuses to prepare a ROSA cluster:

```
SubmarinerClusterEnvironmentPrepared  False
  unsupported vendor "OpenShiftDedicated" for cluster "local-cluster"
```

so no cross-cluster tunnel forms and `clusterset.local` resolves nowhere on a
spoke. Passthrough keeps the grid-CA serving certificate end to end, so a site
still pins the CA out of band.

## The serving certificate does not follow host changes

`grid-enrollment.host` joins the serving certificate SANs, but the bootstrap Job
only creates `enrollment-serving-tls` when it is absent. Changing `host` leaves
the old certificate in place, the new name is missing from the SANs, and a site
fails verification:

```
curl --cacert grid-ca.crt https://<new host>/v1alpha1/enrollments
  http=000 ssl_verify=1
```

The Job's own arguments are correct after the values change; it just skips a
Secret that exists. Deleting the Secret is not enough either, because the Job is
a `pre-install,pre-upgrade` hook and Argo skips the PreSync phase on a sync with
nothing else to do.

### Reissuing it

Back up, delete, and run the bootstrap Job again under a new name. It keeps the
CA, so every pinned bundle and every issued identity stays valid.

```sh
oc -n redhat-ai-grid get secret enrollment-serving-tls -o json > serving-tls-backup.json
oc -n redhat-ai-grid delete secret enrollment-serving-tls

oc -n redhat-ai-grid get job grid-enrollment-ca-bootstrap -o json \
  | jq 'del(.spec.selector, .spec.template.metadata.labels, .status, .metadata)
        | .metadata = {name: "grid-enrollment-ca-reissue", namespace: "redhat-ai-grid"}' \
  | oc apply -f -

oc -n redhat-ai-grid delete pod -l app.kubernetes.io/name=grid-enrollment
```

Confirm the new name is present and the CA did not change:

```sh
oc -n redhat-ai-grid get secret enrollment-serving-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName
oc -n redhat-ai-grid get secret grid-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```

A site verifies when `ssl_verify_result` is 0. The collection answers 405, which
is the method, not a failure.

## Inviting a site

`SiteInvite` is cluster-scoped and declarable; the chart's invite Job and its
ACM delivery policy are not used here. The signer writes the token and reports
where in `status.secretRef`, which is the namespace to read rather than the
release namespace.

```yaml
apiVersion: grid.praxis.fast/v1alpha1
kind: SiteInvite
metadata:
  name: <site>
spec:
  siteName: <site>
  jurisdictions: [default]
  lifetime: 168h
```

One live token per site name. A second reports `Invalid("a live site token
already pins this site name")`; revoke the first with
`DELETE /v1alpha1/enrollmenttokens/{tokenId}` as a subject bound to
`grid-enrollment-grid-admin`, or let it expire. The spec is immutable, so delete
and recreate to change an invitation.

## A spoke cannot redeem an invite yet

The platform deploys the grid operator with no `GRID_ENROLL_*` environment and no
CA pin volume, so nothing redeems a delivered token. `apps/rhoai/grid-network` is
gated to the hub for the same reason: a GridNetwork on a site with no identity
makes the operator self-sign its own CA, which forks the trust domain under a
name that collides with the real `grid-ca`.
