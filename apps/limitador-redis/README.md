# Limitador's Redis

Shared storage for Limitador's rate-limit counters, password-protected: Job
`limitador-redis-auth` generates the password once on the cluster and renders
Limitador's URL with it (`manifests/04-limitador-redis-auth.yaml`). The Job
uses the cluster's own `openshift/cli` image, so the cluster needs its
internal image registry.

Two placements; a deployment picks one with the path its
`<deployment>/apps/limitador-redis.yaml` names:

- `apps/limitador-redis/manifests`: one Redis on the hub, exported over
  Submariner, for the hub's Limitador. The hub must run MaaS (Kuadrant's
  `kuadrant-system`); a hub without OpenShift AI uses the other placement.
- `apps/limitador-redis/ingress`: a Redis on each ingress and combined spoke,
  for that spoke's own Limitador, not exported.

Changing placement deletes the old Redis and its counters.

Upgrading a cluster whose Redis ran without a password: after the sync,
restart Limitador (`oc rollout restart deployment/limitador-limitador -n
kuadrant-system`), which reads its URL only at start.
