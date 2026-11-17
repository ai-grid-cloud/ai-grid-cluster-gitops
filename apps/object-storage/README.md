# Object storage

ACM observability (Thanos) needs an S3 bucket. The library treats that as
infrastructure with a contract, not as part of ACM: `apps/acm` installs
MultiClusterObservability and reads the Secret below, and something else
provides it.

## The contract

- Secret `thanos-object-storage` in namespace
  `open-cluster-management-observability`.
- Key `thanos.yaml`: a Thanos object-store configuration
  ([Thanos storage docs](https://thanos.io/tip/thanos/storage.md/)), for
  example:

  ```yaml
  type: s3
  config:
    bucket: <bucket>
    endpoint: <host>:<port>
    insecure: false
    access_key: <access key>
    secret_key: <secret key>
  ```

The bucket must exist. MultiClusterObservability waits until the Secret does.

## Options

A deployment selects at most one of these in the root's `files`, or none and
brings its own:

| Option | Component | What it needs | Use |
|---|---|---|---|
| ODF | `apps/object-storage/odf/application.yaml` | ODF with the Multicloud Object Gateway (`apps/odf`, or the cluster's own ODF) | An ObjectBucketClaim and a Job that renders the claim's bucket and keys into the Secret. |
| Bring your own | none | an S3 endpoint and bucket | Create the Secret above before ACM observability starts, for example with an ExternalSecret from your vault. Never commit the keys. |

## Not covered yet

Loki (`apps/ai-grid-o11y`, the usage-log store) still claims its own ODF
bucket; it has no object-storage input.
