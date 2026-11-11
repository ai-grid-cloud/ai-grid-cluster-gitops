# The lab roots' own manifests

Objects that only upstream's lab roots (`bootstrap/applicationset.yaml` and
`bootstrap/dedicated-hub/`) install. Each is an extra source of the component
that used to carry it, so it keeps its Application:

- `gitops-config/group.yaml`: the lab's `cluster-admins` Group, synced by
  `gitops-config`. A deployment ships its own Group, if it wants one, as one of
  its apps.
