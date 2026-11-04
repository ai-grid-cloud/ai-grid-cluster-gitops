# odh-observability memory (temporary)

RHOAI's monitoring controller, `redhat-ods-applications/odh-observability`, is OOMKilled at its
chart's `512Mi` limit: it caches Secrets, ConfigMaps, Deployments and more across the whole
cluster. While it crash-loops it never reconciles the `Monitoring` CR, so the site runs no
MonitoringStack and no `data-science-collector`, and its conditions stay stale (for example
`MonitoringDependenciesReady=False MissingOperator` although the Cluster Observability Operator is
installed).

[odh-observability #130](https://github.com/opendatahub-io/odh-observability/pull/130)
(RHOAIENG-102611) raises the chart to request `2Gi` and limit `3Gi`. No DSCI or `Monitoring`
field reaches those values, so until the RHOAI build in `../nightly.yaml` carries that chart, this
ConfigurationPolicy sets the same values on the `manager` container of every site. It only asserts
those two fields (`musthave`). The RHOAI operator keeps container resources that differ from its
manifest, so the two don't fight. Until RHOAI creates the Deployment, the policy reports
NonCompliant; that is expected.

**Remove this chart and its source in `../hub/01-applicationset.yaml` once a fresh install of the
pinned RHOAI build renders `odh-observability` with these values.** Removing it leaves the values
on the Deployment, which by then match the operator's own.
