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
| S4 | `apps/object-storage/s4/application.yaml` | `apps/external-secrets` (Password generators for its keys), a default StorageClass (50 GiB PVC) | One pod (`rh-aiservices-bu/s4`, Ceph RGW) in the observability namespace. Single replica: demos and tests, not production. |
| ODF | `apps/object-storage/odf/application.yaml` | ODF with the Multicloud Object Gateway (`apps/odf`, or the cluster's own ODF) | An ObjectBucketClaim and a Job that renders the claim's bucket and keys into the Secret. |
| Bring your own | none | an S3 endpoint and bucket | Create the Secret above before ACM observability starts, for example with an ExternalSecret from your vault. Never commit the keys. |

S4's keys are generated on the hub by external-secrets and never leave it:
the ExternalSecret `thanos-object-storage` writes `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `thanos.yaml` into the contract Secret once
(`refreshPolicy: CreatedOnce`), and a Sync hook Job creates bucket `thanos`.

## Not covered yet

Loki (`apps/ai-grid-o11y`, the usage-log store) still claims its own ODF
bucket; it has no object-storage input.
