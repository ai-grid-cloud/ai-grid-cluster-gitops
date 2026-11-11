# Tenant access: API keys and checks

These steps follow [first use, part 6](https://github.com/ai-grid-cloud/ai-grid-deployment-template/blob/main/docs/install/07-first-use.md#6-call-the-model-as-a-tenant), and use its token file
`$T/auth`. `MAAS_HOST` is the site's MaaS hostname, `maas.SITE_APPS_DOMAIN`.

## Check the refusals

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://MAAS_HOST/v1/models
curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/auth" -H 'X-MaaS-Subscription: OTHER_SUBSCRIPTION' \
  -H 'Content-Type: application/json' -d '{"model":"MODEL_NAME","messages":[{"role":"user","content":"Hi"}]}' \
  https://MAAS_HOST/v1/chat/completions
```

Replace `OTHER_SUBSCRIPTION` with a subscription that doesn't include the model. You should see `401` without a
token, and `403` with a subscription that doesn't cover the model.

## Create an API key and call with it

A key is bound to one subscription when you create it:

```sh
(umask 077
curl -sS -H @"$T/auth" -H 'Content-Type: application/json' \
  -d '{"name":"KEY_NAME","expiresIn":"1h","subscription":"SUBSCRIPTION_ID"}' \
  https://MAAS_HOST/v1/api-keys > "$T/key.json"
jq -r '"Authorization: Bearer " + .key' "$T/key.json" > "$T/key-auth")
jq '{id, keyPrefix, subscription, expiresAt}' "$T/key.json"
curl -sS -H @"$T/key-auth" https://MAAS_HOST/v1/models | jq -c '[.data[].id]'
curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/key-auth" -H 'Content-Type: application/json' \
  -d '{"model":"OTHER_MODEL","messages":[{"role":"user","content":"Hi"}]}' https://MAAS_HOST/v1/chat/completions
```

Replace `KEY_NAME` with a name for the key, and `OTHER_MODEL` with a deployed model that `SUBSCRIPTION_ID` doesn't
cover; with only one model, skip that call.

You should see the key's `id`, `keyPrefix`, `subscription` and `expiresAt`; the models that subscription covers; and
`403` for a model it doesn't cover. Keep the `id` as `KEY_ID`. The chat call from first use, with `$T/key-auth` in
place of `$T/auth`, returns a reply and an `x-grid-site` header.

A key ignores the `X-MaaS-Subscription` header and always uses the subscription it's bound to. This is MaaS's design
(its e2e test
[`test_api_key_ignores_subscription_header`](https://github.com/opendatahub-io/models-as-a-service/blob/8d30ae9adcda2a9cddc5c33b3a3121037c72a851/test/e2e/tests/test_models_endpoint.py#L1867-L1875)).
To limit what a key reaches, create it under a subscription that covers only those models.

Tenants can also create keys in the Org UI, at `https://MAAS_HOST/maas-portal` under **API keys**.

## Revoke a key

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE -H @"$T/auth" https://MAAS_HOST/v1/api-keys/KEY_ID
curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/key-auth" https://MAAS_HOST/v1/models
rm -rf "$T"
```

You should see `200` for the delete, and `403`, not `401`, for a call with the revoked key.
