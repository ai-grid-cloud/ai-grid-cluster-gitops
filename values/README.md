# The lab's deployment values

Upstream's lab roots (`bootstrap/applicationset.yaml` and
`bootstrap/dedicated-hub/`) use this repository as their deployment repository
as well as their library, so the components that read a deployment's files
(`bootstrap/hub/README.md`, "Files a deployment repository holds") read them
here:

- `cluster-admins.yaml`: the lab's cluster admins (`cluster-config`).
- `grid-bootstrap.yaml`: the lab's grid enrollment values (`grid-bootstrap`).

A hub installed from a deployment repository never reads this directory: its
deployment repository holds its own `values/`.
