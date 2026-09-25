
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

.PHONY: all
all: help

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster

KIND_IMAGE ?= kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a
CLUSTER ?= harbor

.PHONY: cluster
cluster: kind ## Create the kind cluster (offline: `make images-load` first, the cached node image is used).
	@img='$(KIND_IMAGE)'; \
	if ! docker image inspect "$$img" >/dev/null 2>&1 && docker image inspect "$${img%@*}" >/dev/null 2>&1; then \
	  echo "node image $$img not in Docker, using the cached $${img%@*}"; img="$${img%@*}"; fi; \
	$(KIND) create cluster --name $(CLUSTER) --image "$$img" --config hack/config/kind-cluster.yaml

.PHONY: cluster-delete
cluster-delete: kind ## Delete the kind cluster.
	$(KIND) delete cluster --name $(CLUSTER)

.PHONY: cluster-ctx
cluster-ctx: ## Sets cluster context.
	@kubectl config use-context kind-$(CLUSTER)

##@ Networking

LB_IP ?= 172.20.0.100
HARBOR_HOST ?= core.harbor.domain
.PHONY: add-host
add-host: ## Add harbor host to /etc/hosts.
	@./hack/add_host.sh $(LB_IP) $(HARBOR_HOST)

##@ Tooling

KIND ?= $(LOCALBIN)/kind
KIND_VERSION ?= v0.30.0

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

kind: $(KIND) ## Download kind locally if necessary.
$(KIND): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/kind@$(KIND_VERSION)

##@ Harbor

KEEPALIVED_IMAGE ?= harbor-ha/keepalived:2.3.4-alpine3.24

.PHONY: keepalived-image
keepalived-image: kind ## Build the Keepalived image and load it into the lb nodes.
	docker build -t $(KEEPALIVED_IMAGE) hack/ha/keepalived
	$(KIND) load docker-image $(KEEPALIVED_IMAGE) --name $(CLUSTER) --nodes $$(kubectl get nodes -l harbor-ha/role=lb -o name | sed 's|node/||' | paste -sd,)

.PHONY: infra-lb
infra-lb: keepalived-image ## Install the Infra LB (Keepalived VIP + HAProxy on the lb nodes; the Harbor backends appear with `make harbor-ha`).
	@kubectl apply -f hack/ha/00-namespace.yaml -f hack/ha/infra-lb.yaml
	@kubectl -n harbor-deps rollout status daemonset/infra-lb --timeout=180s

.PHONY: harbor-ha
harbor-ha: ## Install Harbor in HA mode (needs `make ha-deps`; reachable through `make infra-lb`). DRY_RUN=1 renders against the cluster only.
	@DRY_RUN=$(DRY_RUN) ./hack/install-harbor-ha.sh

.PHONY: install
install: ## Install Harbor (infra-lb + harbor-ha).
	@./hack/install.sh

##@ HA dependencies

.PHONY: ha-deps
ha-deps: consul postgres redis harbor-lb s3 ## Install all HA dependencies in order (after `make cluster`).

.PHONY: consul
consul: ## Install Consul x3 (DCS for Patroni) on the consul nodes.
	@kubectl apply -f hack/ha/00-namespace.yaml -f hack/ha/consul.yaml
	@kubectl -n harbor-deps rollout status statefulset/consul --timeout=300s

PG_IMAGE ?= harbor-ha/patroni:4.1.5-pg15.19

.PHONY: pg-image
pg-image: kind ## Build the PostgreSQL+Patroni image and load it into the pg nodes.
	docker build -t $(PG_IMAGE) hack/ha/patroni
	$(KIND) load docker-image $(PG_IMAGE) --name $(CLUSTER) --nodes $$(kubectl get nodes -l harbor-ha/role=pg -o name | sed 's|node/||' | paste -sd,)

.PHONY: postgres
postgres: pg-image ## Install PostgreSQL x2 under Patroni (needs `make consul` first).
	@kubectl apply -f hack/ha/00-namespace.yaml
	@kubectl -n harbor-deps get secret pg-credentials >/dev/null 2>&1 || kubectl -n harbor-deps create secret generic pg-credentials \
	  --from-literal=superuser=$$(openssl rand -hex 16) --from-literal=replication=$$(openssl rand -hex 16) --from-literal=harbor=$$(openssl rand -hex 16)
	@kubectl apply -f hack/ha/postgres.yaml
	@kubectl -n harbor-deps rollout status statefulset/pg --timeout=300s

.PHONY: redis
redis: ## Install Valkey x3 + Sentinel sidecars on the redis nodes.
	@kubectl apply -f hack/ha/00-namespace.yaml
	@kubectl -n harbor-deps get secret redis-credentials >/dev/null 2>&1 || kubectl -n harbor-deps create secret generic redis-credentials \
	  --from-literal=password=$$(openssl rand -hex 16)
	@kubectl apply -f hack/ha/redis.yaml
	@kubectl -n harbor-deps rollout status statefulset/redis --timeout=300s

.PHONY: harbor-lb
harbor-lb: ## Install the Harbor LB (HAProxy x2) in front of PostgreSQL and Redis (needs postgres + redis).
	@kubectl apply -f hack/ha/00-namespace.yaml -f hack/ha/haproxy.yaml
	@kubectl -n harbor-deps rollout status deployment/harbor-lb --timeout=180s

.PHONY: s3
s3: ## Install Garage (S3 stand-in for Ceph RGW) on the s3 node, bucket registry-blobs and a scoped key for Harbor.
	@kubectl apply -f hack/ha/00-namespace.yaml
	@kubectl -n harbor-deps get secret s3-credentials >/dev/null 2>&1 || kubectl -n harbor-deps create secret generic s3-credentials \
	  --from-literal=rpc-secret=$$(openssl rand -hex 32) --from-literal=admin-token=$$(openssl rand -hex 16) \
	  --from-literal=harbor-access-key=GK$$(openssl rand -hex 12) --from-literal=harbor-secret-key=$$(openssl rand -hex 32)
	@kubectl apply -f hack/ha/s3.yaml
	@kubectl -n harbor-deps rollout status statefulset/garage --timeout=300s
	@./hack/ha/s3-init.sh

##@ Demo app

.PHONY: deploy-app
deploy-app: ## Build, push, and deploy the demo app (run after `install`).
	@CLUSTER=$(CLUSTER) HARBOR_HOST=$(HARBOR_HOST) LB_IP=$(LB_IP) ./hack/deploy-app.sh

##@ Image cache

.PHONY: images-save images-load images-check images-status
images-save: ## Save the pinned third-party images and charts into the local cache (IMAGE_CACHE, default ~/.cache/harbor-ha).
	@./hack/image-cache.sh save
images-load: ## Load the cached images into the nodes (run after `make cluster`, before `make ha-deps`).
	@CLUSTER=$(CLUSTER) KIND=$(KIND) ./hack/image-cache.sh load
images-check: ## Check online that every pinned image and chart is still pullable (before deleting a working stand).
	@./hack/image-cache.sh check
images-status: ## Show what is in the image cache.
	@./hack/image-cache.sh status

##@ Verification

.PHONY: verify
verify: ## Run the Ansible checks V1..V12 (TAGS=V5,V6 for a subset, EXTRA='-e verify_rollout=true'); needs ansible + kubernetes.core.
	@./ansible/run.sh $(if $(TAGS),--tags $(TAGS)) $(EXTRA)
