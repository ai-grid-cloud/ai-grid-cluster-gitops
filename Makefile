# Offline checks. Nothing here talks to a cluster.
RENDER_CACHE ?= $(CURDIR)/.cache/render
export RENDER_CACHE

.PHONY: help render
help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

# CLUSTERS names the ManagedClusters and their labels; DEPLOYMENT and
# DEPLOYMENT_PATH the deployment values; CATALOG a catalog checkout (default:
# an empty one, for a deployment that lists acm-models).
CLUSTERS ?= hack/render/clusters.json
DEPLOYMENT ?= $(CURDIR)
DEPLOYMENT_PATH ?= deployment
CATALOG ?= hack/render/catalog
render: $(RENDER_CACHE)/appsetgen ## Render every Application for a deployment, offline, and fail on any error
	python3 hack/render/render.py --clusters $(CLUSTERS) --deployment $(DEPLOYMENT) --path $(DEPLOYMENT_PATH) \
	  $(if $(CATALOG),--catalog $(CATALOG)) --skip-schema

$(RENDER_CACHE)/appsetgen: hack/render/main.go hack/render/go.mod hack/render/go.sum
	cd hack/render && go build -o $@ .
