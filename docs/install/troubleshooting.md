# Troubleshooting after install

Each entry gives the symptom, the cause and the fix. For problems during the install, see the install guide's
[troubleshooting](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/troubleshooting.md).
The [hub](hub/README.md) and [spokes](spokes/README.md) pages list more under **Known issues**.

## Every model call returns `403`, "access denied to requested subscription"

**Cause:** the token's `groups` are already prefixed with the organization ID (`ORG_ID/ai-grid-users`). MaaS adds the
prefix itself and drops groups that already carry one.

**Fix:** emit plain group names from the IdP ([tenant identity provider](hub/04-tenant-identity.md#tenant-identity-provider)).

## A chat call returns `400` "Field required: messages" or a template error

**Cause:** the model has no chat template (such as OPT-125m), and the MaaS gateway sends completions to the chat
endpoint.

**Fix:** deploy a chat model.

## Calls fail with `401` or `503` after the IdP was down

**Cause:** Authorino on the site cached the failed OIDC discovery or the old signing keys.

**Fix:** `oc --context SITE_CONTEXT rollout restart deployment/authorino -n kuadrant-system` on each ingress or combined
site.
