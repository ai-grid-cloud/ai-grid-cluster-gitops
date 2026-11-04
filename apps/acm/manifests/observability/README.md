# Optional hub capacity

Add `components: [components/capacity]` to this directory's kustomization to
retain raw metrics for 45 days, five-minute downsampled metrics for 90 days,
and hourly metrics for 365 days. Size object storage for measured ingestion
and downsampling overhead before enabling it. The base already supplies a
101Gi compactor volume and two receivers. Scrape intervals remain owned by
the individual ScrapeConfigs, including `rhai-metrics`.

For an existing default NooBaa pv-pool, set `backingStoreCapacity.enabled: true`
in `apps/odf/chart/values.yaml` and adjust its volume count and agent resources.
The shipped example uses four volumes, requests 500m CPU and 1Gi memory per
agent, and limits each agent to 1 CPU and 2Gi memory. Those resource settings
restored compaction after agent OOMs on one ODF 4.22 deployment; they are not
a general sizing guarantee. The SSA partial preserves the operator's storage
request and class. Set the volume count at least as high as the existing
count; this profile does not shrink volumes or migrate storage. Changing
agent resources replaces all agents and can interrupt every bucket in the pool.

Both options are disabled by default and can be enabled independently.
Disabling the NooBaa option leaves the store and its applied settings in place
because pruning and deletion are disabled. Removing the retention component
restores the base retention configuration and can delete older blocks. The
base's seven-day five-minute retention was rejected by the tested Thanos
version; correct that baseline separately before withdrawing this component.

Site metrics belong to RHOAI's MonitoringStack. Configure
`services.monitoring.dsci.metrics.storage.size` and `.retention` through the
existing RHOAI values, role files or per-site `values-<name>.yaml` overrides.
These become DSCInitialization monitoring settings; this profile does not
manage platform or user-workload Prometheus. Changing a desired storage size
does not establish that existing PVCs have expanded, and volumes cannot shrink.
