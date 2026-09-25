# CLAUDE.md

Repo: **harbor-prod-mirror-on-kind**. Fork of `harbor-active-active-on-kind` @ `7279079` (2026-09-25, full history kept, `origin` unset — not pushed anywhere yet), which is itself a fork of `harbor-on-kind` @ `b65df71`. Same 14-node KinD HA lab, but aimed at mirroring one specific production stand instead of the parent's general HA scheme: Harbor **`2.14.3`** (not 2.15.2), HAProxy **+ Keepalived** as the Infra LB (not MetalLB/ingress-nginx), external PostgreSQL downgraded to **`15.19`** (not 18.6) to match what chart `1.18.3` documents. Redis Sentinel, Patroni + Consul, Garage stay as in the parent (D11–D14, `backlog.md`).

**Status:** fork just created (P0) — decisions and versions are pinned in `backlog.md`, but **the code under `hack/` and `hack/config/` is still byte-for-byte the parent's**: `make cluster/infra-lb/ha-deps/harbor-ha` right now still deploy MetalLB+ingress-nginx, Harbor chart 1.19.2, PostgreSQL 18.6, exactly like the parent. Nothing in this paragraph is done until backlog.md's P1–P6 tick `[x]`. Everything the parent's CLAUDE.md said about Phases 0–4/H5.x/Phase 6 is still true of the inherited code, and is not repeated here — see `backlog.md`'s "Унаследовано от родителя" section.

## Rules

- Work `backlog.md`'s **P0–P6 plan** in order and tick `- [ ]` → `- [x]` when an item is finished, with the result recorded there. The inherited Phase 0–4/H5.x/Phase 6 items below "Унаследовано от родителя" are already closed history from the parent; don't re-do them, but the code they describe is what P1–P6 will change.
- **Ask when a new decision appears, do not pick silently.** This fork's own decisions are D11–D14 in `backlog.md` (Keepalived replaces Infra LB, Harbor 2.14.3/chart 1.18.3 with the official image since the vendor build `v2.14.3-fa517e2a` is unreachable, PostgreSQL downgraded to 15.19, own minimal Keepalived image). Inherited from the parent: D1 14 nodes (1 control-plane + app×2, lb×2, pg×2, redis×3, consul×3, s3×1), D2 Patroni + Consul, D3 Redis Sentinel (an *assumption*, the prod mode is unknown — this fork confirms Sentinel matches prod), D4/D4a S3 = Garage, D5 one lab cluster at a time, D6 two-stage success, D7 HAProxy as Harbor LB (its own note that prod likely uses keepalived for the shared address is exactly what D11 now implements), D8 minimum scope, D9/D10 colors ignored and Nexus out of scope.
- **Don't invent versions.** Every new component gets an explicit pinned version (and image digest) recorded in `backlog.md`, `README.md` and the table below **before** it is installed. Verify Harbor chart keys with `helm show values harbor/harbor --version 1.18.3` (not `1.19.2` — that's the parent's), not from memory.
- Target architecture: Harbor app ×2 → Harbor LB ×2 (HAProxy, in front of PostgreSQL and Redis, **not** the Harbor ingress) → PostgreSQL ×2 under Patroni with state in Consul ×3, Redis ×3; blobs in S3 (Ceph in prod, Garage here); Infra LB **HAProxy + Keepalived (D11; replaces the parent's ingress-nginx + MetalLB)** in front. Backups, Prometheus and Nexus are out of scope.
- **One lab cluster at a time (D5, inherited):** the defaults (`CLUSTER=harbor`, `LB_IP=172.20.0.100`, pool `172.20.0.100–110`) match both `harbor-on-kind` and the parent — so only one of the **three** repos' clusters can run at a time now; `make cluster-delete` whichever of the other two is up before `make cluster` here. The host's `/etc/hosts` entry and Docker `insecure-registries` for `core.harbor.domain` are reused.
- The failure tests kill real nodes and pods. Say what you are about to break before doing it, run one test at a time on a healthy stand, wait for the host load to settle (`cut -d' ' -f1 /proc/loadavg` < 3), and clean up by digest.
- Before `make cluster-delete` of a working stand, run `make images-save` (cache complete) and `make images-check` (pinned images and charts still pullable; `MISSING` = the registry answered not found/unauthorized, `UNKNOWN` = timeout or network/CDN error on this host, not absence; rerun). MinIO's images vanished from quay.io between two builds. A new third-party image must be added to `hack/images.txt` with its node roles.
- Report faithfully: a failed or skipped check is reported as such, with its output.
- `sudo` is interactive-only in agent sessions: `make add-host` (missing entry) and the Docker `insecure-registries` change are run by the user; `make deploy-app` prints the exact commands.
- Never write to the user's `~/.aws` (no `aws configure set`); for S3 checks use an isolated `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` (runbook V8.2).
- `hack/config/harbor.yaml` (single-node values) is legacy: HA replaced the single-node baseline on purpose (H3.3) and no target uses it.

## Pinned versions

**Below is still the parent's table — what `hack/` actually deploys right now.** The fork's target pins (chart `1.18.3`/app `2.14.3`, PostgreSQL `15.19-alpine3.24`, image digests, Keepalived TBD) are in `backlog.md`'s "Закреплённые версии" table and only take effect as P1–P6 land; update this table in place as each phase lands, don't duplicate it.

| Component | Pinned version |
|-----------|----------------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` — **to be removed in P2 (D11)** |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) — **to be removed in P2 (D11)** |
| Harbor chart / app | `1.19.2` / `2.15.2` — **to become `1.18.3` / `2.14.3` in P3 (D12)** |
| PostgreSQL | `18.6-alpine3.24` (Harbor 2.15.2 bundles 18.3) — **to become `15.19-alpine3.24` in P4 (D13)** |
| Patroni | `4.1.5` (PyPI, own image, extras `consul`, `psycopg3`) — unchanged |
| Consul | `1.22.7` (not 2.0.x) — unchanged |
| HAProxy | `3.4.4-alpine3.24` (LTS) — unchanged pin, but gets a second role (Infra LB) in P2 |
| Valkey + Sentinel | `9.0.6-alpine3.24` (Harbor bundles 9.0.3) — unchanged |
| Garage (S3) | `v2.4.1` (Docker Hub `dxflrs/garage`) — unchanged |
| Keepalived | not yet picked — **P2, D14: own minimal Alpine + `apk add keepalived` image, not a third-party one** |

Images are also pinned by digest in the manifests; full refs and rationale are in `backlog.md` → "Версии компонентов HA" (parent) and "Закреплённые версии" (this fork's changes). Chart `1.19.2` HA keys in use: `database.type` / `redis.type: external` + `*.external.*`, `persistence.imageChartStorage.type: s3` (`disableredirect: true`), `replicas`, `nodeSelector`, `tolerations`, `topologySpreadConstraints`, `livenessProbe` under `core`/`portal`/`registry`/`jobservice`/`trivy`, `expose.tls.certSource: secret`, `caSecretName`. **P3 gotcha, already confirmed against chart `1.18.3`:** `core.livenessProbe`/`readinessProbe` and `jobservice.livenessProbe`/`readinessProbe` are not values-configurable in `1.18.3` (hardcoded in the templates: core `failureThreshold: 2`, jobservice `initialDelaySeconds: 300`, neither has a settable `timeoutSeconds`) — the parent's H4.7 relaxed-liveness fix must move from `hack/config/harbor-ha.yaml` into `hack/helm-postrender.py` instead, or it silently does nothing and core/jobservice restart during a Redis failover again.

## Commands

```bash
make help            # list targets
make cluster         # installs ./bin/kind if missing, creates the 14-node cluster "harbor" (hack/config/kind-cluster.yaml, context kind-harbor)
make infra-lb        # MetalLB + ingress-nginx x2 on the lb nodes (hack/install-infra.sh)
make ha-deps         # consul -> postgres -> redis -> harbor-lb -> s3, in this order; each can run alone
                     #   consul | pg-image | postgres | redis | harbor-lb | s3   (hack/ha/*.yaml, namespace harbor-deps, secrets generated on first run)
make add-host        # "$LB_IP $HARBOR_HOST" into /etc/hosts (sudo)
make harbor-ha       # hack/install-harbor-ha.sh: Secrets in `default` (once), then helm install with hack/config/harbor-ha.yaml + hack/helm-postrender.py; DRY_RUN=1 renders only
make install         # infra-lb + harbor-ha
make deploy-app      # project `python`, build/push demo image, CA trust on the control-plane node, pull secret, deploy (idempotent)
make verify          # ansible/verify.yml: checks V1..V12 with a PASS/FAIL table, non-zero exit on FAIL (TAGS=V5,V6, EXTRA='-e verify_rollout=true'); needs pip `kubernetes` + collection kubernetes.core
make images-save     # hack/image-cache.sh: pinned third-party images + charts (hack/images.txt) into ~/.cache/harbor-ha (IMAGE_CACHE=)
make images-load     # cached images into the nodes of the right role (run before `make cluster` for the Docker daemon, again after it for the nodes); images-check / images-status
make cluster-ctx     # kubectl use-context kind-harbor
make cluster-delete
```

Variables: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`, `PG_IMAGE`. Tests: `hack/tests/h41…h47`, `h62-sync-mode.sh` (see `README.md`). Checks: `docs/verification-runbook.md` (V1–V12, P4.1–P4.7); run the relevant ones after any change to `hack/ha/` or `hack/config/` and keep the runbook in sync.

## Gotchas

**Build and host**

- The Makefile runs `go env GOBIN` at parse time: Go must be on `PATH` even for `make help`. `$(KIND)` is a file target: after bumping `KIND_VERSION` delete `./bin/kind`. Kind clusters are never upgraded in place.
- `hack/add_host.sh` skips the entry if the hostname is present (it will not fix a wrong IP). Use `systemctl reload docker`, not `restart`, while a cluster runs.
- The subnet of the Docker `kind` network varies per machine (`docker network inspect kind`; here `172.20.0.0/16`). Changing `LB_IP` means updating together: `Makefile`, `hack/config/lb-ipaddresspool.yaml`, `hack/config/nginx.yaml`, host `/etc/hosts`, the node's `/etc/hosts`, README examples.
- Everything shares one host disk: gigabytes of writes (image builds with `dd`, big pushes) stall etcd/apiserver, crash controller-manager/scheduler (leader election; lease 60/40/10 s is set in `kind-cluster.yaml`) and trigger Sentinel failovers (`down-after` 15000). Keep test data small.
- Image cache (`hack/image-cache.sh`): `docker save` drops the name of a digest-pinned image, so images are saved under `cache.local/...:cached` and re-tagged inside the node with `ctr -n k8s.io images tag` to the pinned name; do not replace this with a plain `kind load docker-image`.
- Cold-start image pulls fail transiently (`ErrImagePull`): pods self-heal. Third-party images can vanish (MinIO). The output of `make pg-image` is loaded with `kind load` into the `pg` nodes only and disappears with the cluster.
- MetalLB L2: if a `LoadBalancer` IP never resolves (ARP `(incomplete)`, speaker flapping `serviceAnnounced`/`serviceWithdrawn`), check `kubectl get endpoints <svc>` and pod status first.

**Harbor chart, TLS, rollouts**

- The chart resolves `existingSecret` with `lookup` at render time: the Secrets must exist before `helm install`; validate with `DRY_RUN=1 make harbor-ha`, not `helm template`.
- The token key must be PKCS#1 (`openssl genrsa -traditional`). The CA is created once (Secret `harbor-ha-ingress-tls`, `certSource: secret`): with `auto` every `helm upgrade` regenerates it and new pulls on the node fail with `x509: unknown authority`. `deploy-app` trusts it on the node (needed once).
- The chart has no `preStop`: `hack/helm-postrender.py` (PyYAML, used by `install-harbor-ha.sh`) adds `preStop: sleep 15` to core/registry/portal; without it rolling updates give 502s. Keep it when changing the install path.
- 2 replicas on a 2-node role: `topologySpreadConstraints` (maxSkew 1) with `matchLabelKeys: [pod-template-hash]`, not a required `podAntiAffinity` (it deadlocks rolling updates). `harbor-lb` rolls with `maxSurge: 0`; HAProxy needs a `config-version` annotation bump to roll after a config change.
- Every worker is tainted `harbor-ha/role=<role>:NoSchedule`: any new workload needs a `nodeSelector` and a toleration. The demo app runs on the control-plane node (the only place `deploy-app.sh` installs the CA).
- `kubernetes.core.k8s_exec` splits `command` with shlex and runs no shell: use `sh -c "... $VAR ..."` (a `\$VAR` stays literal). Ansible checks (`ansible/`): each role appends to `verify_results`; skip `Terminating` pods (`deletionTimestamp`), they still report `Running`.
- Kubernetes does not expand `$(HOSTNAME)` in `args`: use the downward API (`POD_NAME`).

**Redis, HAProxy, S3**

- A restarted `redis-0` must not become master before it has asked the peers (`start-valkey.sh`: fresh volume vs restart); Valkey runs with `min-replicas-to-write 1`; the HAProxy Redis check requires `role:master` and a connected replica (regex `role:master[^a-z]{1,4}connected_slaves:[1-9]`; in HAProxy regexes `.` does not match a newline). Harbor core/jobservice liveness is relaxed (5 s x 6): their probes hang while Redis is unreachable.
- The Garage image has no shell: `hack/ha/s3-init.sh` runs `/garage` with `kubectl exec`. Bucket `registry-blobs`, key `harbor` (Secret `s3-credentials`).

**Failure tests and Harbor test data**

- Delete Harbor test artifacts by **digest**, never by tag: deleting an artifact removes all its tags (a test tag on the digest of `python/hello:1.0` deleted the demo image once).
- The scripts always restore what they change (killed node started again, `tc` removed, CoreDNS Corefile restored). If one is interrupted: `docker start <node>`, check `kubectl get nodes`, `docker exec harbor-worker tc qdisc show dev eth0` (expect `noqueue`) and `kubectl -n kube-system get cm coredns` (the original Corefile has no `template` block; then `rollout restart deploy/coredns`).
- H4.6 needs a fresh proxy project name per run (deleting through the API leaves blobs in S3) and does its cold pull with `curl`: docker's content store hides blobs from Harbor. Cached content is addressed by digest, tag pulls need the upstream.

## Coupling of the entry path

**Still the parent's diagram — this is exactly what P2 (D11) replaces with Keepalived + HAProxy.** Update in place once P2 lands.

```
host: /etc/hosts core.harbor.domain -> 172.20.0.100
  MetalLB L2 pool 172.20.0.100-110 (hack/config/lb-ipaddresspool.yaml)
  ingress-nginx x2 on the lb nodes, Service pinned to 172.20.0.100 (hack/config/nginx.yaml, metallb.universe.tf/loadBalancerIPs)
  Harbor (expose.type=ingress, className nginx, host core.harbor.domain, TLS from Secret harbor-ha-ingress-tls) - hack/config/harbor-ha.yaml
```

Registry trust outside `deploy-app`: host Docker `insecure-registries: ["core.harbor.domain"]`; for the node, fetch `ca.crt` (`curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert`), `docker cp` it to `<cluster>-control-plane:/usr/local/share/ca-certificates/`, `update-ca-certificates`, add the hosts entry, `systemctl restart containerd`.

## Demo app

- `python-docker-hello-kube/hello.py` is stdlib-only `http.server` (no pip dependencies: the original Flask app broke on an unpinned Werkzeug). `GET /` → `Hello, Kube! (from <pod hostname>)` (shows which replica answered), `GET /healthz` → `ok`, port 5000. The Dockerfile pins `python:3-alpine@sha256:9e9fde4d…`.
- `deployment.yml` (2 replicas + LoadBalancer `hello-service`, label `app: hello`) and `helm-hello-kube/templates/deployment.yaml` have probes on `/healthz`; both carry the control-plane `nodeSelector`/toleration.
- `helm-hello-kube/`: Deployment/Service names and the `app: hello-kube` selector are hardcoded; `helm test` works only for a release named `hello-kube`. Chart `appVersion: "1.16.0"` differs from image tag `1.0`: harmless.
- Must stay identical across the Dockerfile usage, `deployment.yml` and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor` (`docker-registry`), port `5000`. Charts go via Helm OCI (`helm push … oci://core.harbor.domain/python/hello --ca-file ./ca.crt`), not ChartMuseum.

## Conventions

- Always pass `--version` to every `helm upgrade -i` (`hack/install-infra.sh`, `hack/install-harbor-ha.sh`, any new script). Prefer `make` targets over ad-hoc kind/helm commands.
- Don't commit `bin/`, `ca.crt`, `*.tgz` or real credentials (`admin` / `Harbor12345` is the lab-only default); generated passwords live only in Secrets. `.gitignore` covers the files.
- Keep `README.md` and `AGENTS.md` in sync with `Makefile` / `hack/` whenever pins, topology or the demo app change.
