# harbor-prod-mirror-on-kind

Mirror of one specific production stand on a single machine: a 14-node KinD cluster with Harbor **2.14.3** (chart `1.18.3`) in active-active, **Keepalived + HAProxy** as the Infra LB, external PostgreSQL **15.19** under Patroni + Consul, Redis Sentinel and Garage S3 (stands in for Ceph RGW). Fork of [harbor-active-active-on-kind](https://github.com/it255ru/harbor-active-active-on-kind) (@ `7279079`, full history kept), which itself forks [harbor-on-kind](https://github.com/it255ru/harbor-on-kind); the differences from the parent are decisions D11-D17 in [backlog.md](backlog.md). Published at https://github.com/it255ru/harbor-prod-mirror-on-kind.

**Status (2026-09-25):** the stand builds from scratch (about 10 minutes with the image cache), `make verify` gives 38 PASS / 0 FAIL and the failure tests in `hack/tests/` (h41-h48, h62) were run on this stack; the results are in the table under "Failure behaviour" and in `backlog.md` → P5. Node/address map: [docs/stand-topology.md](docs/stand-topology.md). Check-by-check procedure: [docs/verification-runbook.md](docs/verification-runbook.md).

## Architecture

14 KinD containers: 1 control-plane and 13 workers. Every worker has the label and taint `harbor-ha/role=<role>` (`NoSchedule`).

| Role | Nodes | Runs |
|------|-------|------|
| app | 2 | Harbor nginx (the entry point), core, portal, registry, jobservice (2 replicas each) and Trivy (1) |
| lb | 2 | HAProxy "Harbor LB" (PostgreSQL and Redis entry point); Infra LB: Keepalived (VIP) + HAProxy on every lb node |
| pg | 2 | PostgreSQL 15 under Patroni |
| redis | 3 | Valkey with a Sentinel sidecar (1 master, 2 replicas) |
| consul | 3 | Consul servers, the DCS for Patroni |
| s3 | 1 | Garage, stands in for Ceph RGW (registry blobs) |

```text
client -> 172.20.0.100 (Keepalived VIP) -> HAProxy (Infra LB, TCP) -> Harbor nginx (app) -> core/registry -> HAProxy (Harbor LB) -> PostgreSQL primary / Redis master
                                                              \-> Garage (S3 blobs)        PostgreSQL state -> Consul
```

HAProxy is the entry point for the databases, not for Harbor: it sends PostgreSQL traffic to the Patroni leader (`GET /primary`) and Redis traffic to the master that has a connected replica. Backups, Prometheus and Nexus of the original scheme are out of scope.

## Requirements

- Linux host with Docker, Go, `kubectl`, `helm` 3.x, `openssl`, `python3` with PyYAML (Helm post-renderer). `kubectl` within one minor version of the pinned Kubernetes.
- Host inotify limits for 14 nodes: `fs.inotify.max_user_instances=2048`, `fs.inotify.max_user_watches=1048576` (persist in `/etc/sysctl.d/`; needs `sudo`, not managed by this repo).
- Resources measured on the full stand at rest: about 4.5 GiB RAM for the 14 node containers and about 8 GB of Docker images. Image builds and the failure tests add load: use a host with 16 GiB RAM or more and keep the disk free.
- Internet access to Docker Hub, quay.io, registry.k8s.io, PyPI (the Patroni image is built locally) and GitHub. Every pinned image must still be pullable anonymously: check before deleting a working cluster.
- One lab cluster at a time: `make cluster-delete` the `harbor-on-kind` or `harbor-active-active-on-kind` cluster first (same cluster name and LB IP).
- Host prerequisites the repo cannot do for you (interactive `sudo`): a `/etc/hosts` entry (`make add-host`) and `core.harbor.domain` in Docker `insecure-registries`:

```bash
# merge into the existing /etc/docker/daemon.json, then reload (not restart) Docker
{ "insecure-registries": ["core.harbor.domain"] }
sudo systemctl reload docker
```

## Pinned versions

Everything is pinned; changing a pin means updating the manifests, this table, `CLAUDE.md` and `backlog.md` together. Image digests are in `backlog.md` and in the manifests.

| Component | Version |
|-----------|---------|
| Kind CLI | `v0.30.0` |
| KinD node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| Keepalived | `2.3.4-r2` on `alpine:3.24@sha256:294b683c…` (own image, D14) |
| Harbor chart / app | `1.18.3` / `2.14.3` |
| PostgreSQL | `15.19-alpine3.24` |
| Patroni | `4.1.5` |
| Consul | `1.22.7` |
| HAProxy | `3.4.4-alpine3.24` |
| Valkey + Sentinel | `9.0.6-alpine3.24` |
| Garage (S3) | `v2.4.1` |

## Build the stand

```bash
make cluster       # 14-node kind cluster "harbor" from hack/config/kind-cluster.yaml, context kind-harbor
make infra-lb      # builds the Keepalived image, DaemonSet infra-lb (Keepalived VIP + HAProxy) on the lb nodes
make ha-deps       # consul -> postgres -> redis -> harbor-lb -> s3, in this order
make add-host      # "172.20.0.100 core.harbor.domain" in /etc/hosts (sudo, once)
make harbor-ha     # Harbor 1.18.3 (2.14.3) in HA mode; DRY_RUN=1 only renders against the cluster
make deploy-app    # project "python", demo image build/push, CA trust on the node, pull secret, demo app
make cluster-delete
```

**Image cache (optional, recommended).** Every third-party image and chart is pinned, but a registry can still be slow or drop an artifact (MinIO's images vanished, Docker Hub can take minutes per image). `make images-save` keeps the 15 images of `hack/images.txt` and the Harbor chart `1.18.3` in `~/.cache/harbor-ha` (`IMAGE_CACHE=<dir>` to move it; outside the repository); `make images-load` puts each image into containerd of only the nodes that need it. With a cache the build is `make images-load cluster images-load infra-lb ha-deps ...` (the first `images-load` prepares the Docker daemon, the second the nodes; `make cluster` uses the cached node image when the pinned one is absent). `make images-check` tells whether the originals are still pullable. Not cached: PyPI packages of the Patroni image and the `FROM` base images of the two local builds, which Docker cannot hold by digest after a load.

`make install` runs `infra-lb` and `harbor-ha`. Every target is idempotent. The order of `ha-deps` matters (Patroni needs Consul, HAProxy needs the PostgreSQL and Redis backends). `make help` lists all targets; variables: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`, `PG_IMAGE`.

Measured from scratch with the image cache (2026-09-25): `cluster` 52 s, `images-load` into the nodes about 2 min, `ha-deps` about 3 min, `infra-lb` seconds, `harbor-ha` seconds plus about 30 s for the pods, `deploy-app` 10 s, `make verify` about 1 min. Without the cache the times are dominated by image pulls (Docker Hub on this host is slow).

Harbor UI: https://core.harbor.domain (`admin` / `Harbor12345`, the lab default). Passwords of the dependencies are generated on the first run of each target and live only in Secrets: `pg-credentials`, `redis-credentials`, `s3-credentials` (namespace `harbor-deps`) and `harbor-ha-secrets`, `harbor-ha-s3`, `harbor-ha-token`, `harbor-ha-ingress-tls` (namespace `default`). Read one with `kubectl -n harbor-deps get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d`. To reset a component delete its Secret and its PVCs (`data-<name>-N`) together; the state on the volume keeps the old password.

## What a healthy stand looks like

```text
$ kubectl get nodes -L harbor-ha/role
NAME                   STATUS   ROLES           AGE   VERSION   ROLE
harbor-control-plane   Ready    control-plane   65m   v1.34.0
harbor-worker          Ready    <none>          65m   v1.34.0   app
harbor-worker2         Ready    <none>          65m   v1.34.0   app
harbor-worker3         Ready    <none>          65m   v1.34.0   lb
harbor-worker4         Ready    <none>          65m   v1.34.0   lb
harbor-worker5         Ready    <none>          65m   v1.34.0   pg
harbor-worker6         Ready    <none>          65m   v1.34.0   pg
harbor-worker7..9      Ready    <none>          65m   v1.34.0   redis
harbor-worker10..12    Ready    <none>          65m   v1.34.0   consul
harbor-worker13        Ready    <none>          65m   v1.34.0   s3

pods by node (which pod is where inside a role varies between builds):
harbor-control-plane   hello-deployment x2 (demo app)
harbor-worker          harbor-nginx, harbor-core, harbor-jobservice, harbor-portal, harbor-registry
harbor-worker2         harbor-nginx, harbor-core, harbor-jobservice, harbor-portal, harbor-registry, harbor-trivy-0
harbor-worker3/4       harbor-lb, infra-lb (haproxy + keepalived)
harbor-worker5/6       pg-0, pg-1            harbor-worker7/8/9    redis-0, redis-1, redis-2
harbor-worker10/11/12  consul-0, consul-1, consul-2              harbor-worker13   garage-0

$ kubectl -n harbor-deps exec consul-0 -- consul operator raft list-peers
consul-2  ...  leader    true  3  1163  -
consul-1  ...  follower  true  3  1163  0 commits
consul-0  ...  follower  true  3  1163  0 commits

$ kubectl -n harbor-deps exec pg-1 -- patronictl -c /etc/patroni/patroni.yml list
| pg-0 | 10.244.4.2 | Replica | streaming | 3 | 0/3CE36D0 | 0 | 0/3CE36D0 | 0 |
| pg-1 | 10.244.1.3 | Leader  | running   | 3 |           |   |           |   |

$ kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster
OK 3 usable Sentinels. Quorum and failover authorization can be reached

HAProxy backends (one UP each):  postgres/pg-1=UP  redis/redis-1=UP  (the other backends are DOWN by design)
$ kubectl -n harbor-deps exec garage-0 -- /garage bucket info registry-blobs | grep -E '^(Global alias|Objects)'
Global alias:  registry-blobs
Objects:       102
```

The image blobs are in Garage, not on a volume: the only PVC of Harbor itself is Trivy's cache. Roles move: after a failure the leader/master can be on any node of its role, so read the current holder instead of assuming it.

## Verify and test

The runbook ([docs/verification-runbook.md](docs/verification-runbook.md)) has checks V1-V12 (state, placement, services, end-to-end, load distribution) with expected output and diagnostics. `make verify` runs the same checks as an Ansible playbook (`ansible/`, about 1.5 minutes, table of `PASS`/`FAIL`/`WARN` and a non-zero exit code on any failure; `TAGS=V5,V6` for a subset). It needs the Python module `kubernetes` (`pip install --user kubernetes`) and the collection `kubernetes.core` (`ansible-galaxy collection install -r ansible/requirements.yml`).

The failure tests are scripts in `hack/tests/`. They run real load, kill real nodes or pods and clean up after themselves; run one at a time, on a healthy stand, after the host load has settled (`cut -d' ' -f1 /proc/loadavg` below 3).

| Script | What it does | Time |
|--------|--------------|------|
| `h41-push-pull.sh` | push/pull of two images in parallel and an OCI chart with all replicas up; digests, pod pull, `helm test` | 1 min |
| `h42-kill-during-push.sh <registry\|core> <container> <tag>` | kills the pod that is receiving a large push; the client retries, digest intact | 1-2 min |
| `h43-rolling-update.sh` | restarts core, then registry under continuous pulls | 1 min |
| `h44-node-loss.sh [node]` | kills an `app` node under load, waits for eviction, brings it back | 4-8 min |
| `h45-app-rollout.sh` | rolls the demo app to a freshly pushed tag; `DEGRADE=1` with one registry and one core killed | 1 min |
| `h46-proxy-cache.sh` | proxy-cache project for Docker Hub, served from the cache with the upstream cut off | 4 min |
| `h48-node-replace.sh [node]` | permanent loss of an `app` node: kills it for good, deletes the node, builds and joins a replacement, reloads the cached images, resets Trivy's PVC | 6 min |
| `h62-sync-mode.sh <off\|on\|strict>` | what Patroni `synchronous_mode` changes: deletes the replica pod, then the leader pod under a writer; restores the config | 4 min |
| `h47-role-failure.sh <lb\|pg\|redis\|consul\|s3>` | kills the node of the role holder under load, checks lost acknowledged writes (`s3`: the objects in the bucket) | 3-5 min each |

## Failure behaviour (measured)

Measured on this stack (Harbor 2.14.3, PostgreSQL 15.19, Keepalived + HAProxy), 2026-09-25, one run per case; details in [backlog.md](backlog.md) → P5.

| Failure | What clients see | Data |
|---------|------------------|------|
| Replica of core/registry killed during a push | 1-2 x 502, the client retries, the push completes | intact |
| Rolling update of core/registry (`preStop` sleep, see below) | no errors (0 of 318 manifests, 114 blobs, 241 pulls) | intact |
| `app` node lost (nginx, core, portal, registry, jobservice, Trivy) | no stalls: the slowest request was 2.1 s (HAProxy notices the dead nginx in ~2-3 s); 1 of 2208 manifests, 1 of 784 blobs, 1 of 1311 pulls failed (the one in flight at the kill); Trivy is down until the node is back. The internal Services use `trafficDistribution: PreferSameNode` (D17), so a surviving node never calls the dead one | intact |
| Consul leader node | nothing visible (0 errors); raft elects a new leader | intact |
| Redis master node | ~21-25 s without Redis: requests stall up to 21 s, 1 of 38 pushes failed; core/jobservice are **not** restarted | no acknowledged write lost |
| PostgreSQL primary node | ~33 s without writes, 5xx for requests that need the database (122 of 690 manifests, 37 of 243 blobs, 1 of 32 pushes; 0 of 623 pulls) | none lost in the test, but replication is asynchronous |
| `lb` node that holds the Infra LB address (VIP) | the VIP moves to the other node: 2 of 621 manifests failed, longest gap 5.2 s, 0 pull/push failures; no second blip when the node returns (`nopreempt`); new connections to PostgreSQL/Redis through the dead HAProxy fail (19 of 421 / 24 of 442) | intact |
| `s3` node (Garage, the only one, no redundancy) | the whole data path of the registry is down while the node is (~110 s without a successful request through the VIP, manifests are in S3 too; `docker pull` waits up to 65 s and completes; UI, API, PostgreSQL and Redis are not affected); Harbor recovers on its own 13 s after the node returns, no Harbor pod restarts | intact (209 of 209 objects) |
| `app` node lost for good and replaced (`h48`) | manifests 0 of 1353, blobs 1 of 501, 1 of 719 pulls failed (the one in flight at the kill); all Deployments are 2/2 again 231 s after the loss (node deleted 60 s after NotReady, replacement built by hand and joined, images loaded from the cache); Trivy's node-local PVC must be reset (the script does it) | intact |

`synchronous_mode` of Patroni is off (backlog D8); `h62` measured what it would change: with `on` the leader loss costs a 7.3 s write pause instead of 10.3 s and no acknowledged write is at risk while the sync replica lives, with `strict` losing the replica blocks writes for ~16 s.

The windows come from settings: Kubernetes ~47-52 s to declare a node lost, Sentinel `down-after` 15 s, Patroni TTL 30 s, VRRP failover of the Infra LB address. After the node returns everything is healthy again on its own within about a minute.

## Design notes and gotchas

**Placement and rollouts**

- Workers are tainted by role: anything new needs a matching `nodeSelector` and toleration, otherwise it stays `Pending`.
- Two replicas on a two-node role use `topologySpreadConstraints` with `matchLabelKeys: [pod-template-hash]`, not a required `podAntiAffinity`. The anti-affinity deadlocks rolling updates (the surge pod has no third node); without `matchLabelKeys` a rollout can leave both replicas on one node. `harbor-lb` keeps anti-affinity and rolls with `maxSurge: 0`.
- The Harbor chart has no `preStop` hook, so a terminating registry pod still received requests and core answered 502. `hack/helm-postrender.py` (Helm post-renderer used by `make harbor-ha`, needs PyYAML) adds `preStop: sleep 15` to core, registry and portal.
- HAProxy does not reload on a config change: bump the `config-version` annotation in `hack/ha/haproxy.yaml`.

**Redis**

- Split-brain protection: after a node loss a restarted `redis-0` must not become a second master. `start-valkey.sh` waits for the peers on a restart, Valkey runs with `min-replicas-to-write 1`, and HAProxy treats a Redis backend as master only if it also has a connected replica (regex `role:master[^a-z]{1,4}connected_slaves:[1-9]`; `.` does not match a newline in HAProxy regexes). A freshly promoted master is therefore unavailable for a few seconds until a replica syncs.
- Harbor core and jobservice liveness probes are relaxed (timeout 5 s, 6 failures): their probes hang while Redis is unreachable, and the chart defaults made kubelet restart both cores during a Redis failover.

**Harbor and TLS**

- The chart resolves `existingSecret` with `lookup` at render time: the Secrets must exist before `helm install` (the installer creates them). Validate with `DRY_RUN=1 make harbor-ha`, not `helm template`.
- The token key must be PKCS#1 (`BEGIN RSA PRIVATE KEY`); PKCS#8 makes core answer 500 on `/v2/`.
- The registry CA is created once (Secret `harbor-ha-ingress-tls`, `certSource: secret`). With `certSource: auto` the chart regenerates the CA on every `helm upgrade`, and containerd on the nodes then fails new pulls with `x509: certificate signed by unknown authority`. `make deploy-app` trusts the CA on the node (needed once).
- Proxy-cache projects cache by digest: with Docker Hub unreachable a cached image can be pulled by digest, not by tag. The cache appears ~20-40 s after the first pull, and the endpoint URL is ignored for the `docker-hub` type.
- Delete test artifacts by digest, never by tag: deleting an artifact removes all its tags (a test tag on the digest of `python/hello:1.0` deletes the demo image).
- jobservice can restart once or twice on first start (core is not accepting connections yet).
- The demo app runs on the control-plane node (workers are tainted; `deploy-app.sh` installs the CA only there).

**Storage and environment**

- S3 is Garage, one node, one drive, no replication. It replaced MinIO because MinIO's quay.io images became private and are not on Docker Hub. The Garage image has no shell: `hack/ha/s3-init.sh` runs the `garage` CLI through `kubectl exec`.
- Every image is pinned by digest, which does not help if a registry withdraws the repository (that is how MinIO was lost). Run `make images-save` (cache complete) and `make images-check` before deleting a working cluster.
- The PostgreSQL+Patroni image is built locally (`make pg-image`, run by `make postgres`) and loaded with `kind load` into the `pg` nodes only; it disappears with the cluster.
- Everything shares one host disk. Bursts of I/O (image builds, multi-gigabyte pushes) stall etcd and the apiserver: controller-manager and scheduler lose their leader-election lease (timings 60/40/10 s are set in `kind-cluster.yaml`), Valkey logs `AOF fsync is taking too long`, Sentinel may fail over (`down-after` 15 s). Keep test data small.
- Consul has no ACL/TLS, Sentinel has no password, PostgreSQL replication is asynchronous: deliberate for the lab (backlog D8).
- Cold-start image pulls can fail transiently (`ErrImagePull`); pods recover on their own.

## Load balancer IP

Docker picks the subnet of the `kind` network per machine. After `make cluster`:

```bash
docker network inspect -f '{{.IPAM.Config}}' kind
```

The defaults assume `172.20.0.0/16`. If yours differs, update together: `LB_IP` in `Makefile`, `virtual_ipaddress` in `hack/ha/infra-lb.yaml`, host `/etc/hosts` and the node's `/etc/hosts`. `hack/add_host.sh` skips the entry if the hostname already exists, so it will not correct a wrong IP.

## What `make deploy-app` does

Idempotent; safe to re-run after editing `hello.py`.

1. Creates the `python` project in Harbor.
2. Logs in, builds `core.harbor.domain/python/hello:1.0` from `python-docker-hello-kube/` and pushes it.
3. Installs Harbor's CA in the KinD control-plane node (`update-ca-certificates`, hosts entry, `systemctl restart containerd`). Running pods are not affected.
4. Creates the `harbor` docker-registry pull secret.
5. Applies `deployment.yml` and restarts the rollout.

Manual CA fetch, if needed: `curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert -o ca.crt`.

## Demo app

`python-docker-hello-kube/hello.py` is stdlib-only (`http.server`, no pip dependencies), port 5000: `GET /` returns `Hello, Kube! (from <pod hostname>)` (shows which replica answered), `GET /healthz` returns `ok` (probe target).

```bash
kubectl apply -f deployment.yml                 # 2 replicas + NodePort Service hello-service (<control-plane IP>:30500)
helm install hello-kube ./helm-hello-kube       # the release must be named hello-kube for `helm test`
```

Values that must stay identical across the Dockerfile usage, `deployment.yml` and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor`, port `5000`. Charts go to Harbor over OCI (ChartMuseum is deprecated):

```bash
helm package helm-hello-kube
helm registry login core.harbor.domain -u admin --ca-file ./ca.crt
helm push hello-kube-0.1.0.tgz oci://core.harbor.domain/python/hello --ca-file ./ca.crt
helm install hello-kube oci://core.harbor.domain/python/hello/hello-kube --version 0.1.0 --ca-file ./ca.crt
```

## Troubleshooting

More in the runbook. Short list:

- `172.20.0.100` does not respond: find the holder (`docker exec <lb node> ip -4 addr show eth0`), then `kubectl -n harbor-deps logs ds/infra-lb -c keepalived` (VRRP state) and the HAProxy backends (`docker exec <lb node> curl -s 'http://127.0.0.1:8405/stats;csv'`; `harbor_https` needs an UP nginx pod).
- `make` fails even for `make help`: Go must be on `PATH` (the Makefile runs `go env GOBIN` at parse time).
- After bumping `KIND_VERSION`, delete `./bin/kind`, otherwise Make will not reinstall it.
- Kind clusters are not upgraded in place: `make cluster-delete`, then `make cluster`.
- A failure test was interrupted: start the killed node again (`docker start <node>`), check `kubectl get nodes` and the CoreDNS Corefile (`h46` edits it and restores it on exit).

## Credits

Based on [mmontes11/harbor-kind](https://github.com/mmontes11/harbor-kind) via [harbor-on-kind](https://github.com/it255ru/harbor-on-kind).
