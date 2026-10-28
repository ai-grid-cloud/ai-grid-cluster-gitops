# Limitador's Redis

Shared storage for Limitador's rate-limit counters, password-protected: Job
`limitador-redis-auth` generates the password once on the cluster and renders
Limitador's URL with it (`manifests/04-limitador-redis-auth.yaml`). The Job
uses the cluster's own `openshift/cli` image, so the cluster needs its
internal image registry.

Upgrading a cluster whose Redis ran without a password: after the sync,
restart Limitador (`oc rollout restart deployment/limitador-limitador -n
kuadrant-system`), which reads its URL only at start.
