# Agent context: harbor-prod-mirror-on-kind

Fork of `harbor-active-active-on-kind` @ `7279079` (itself a fork of `harbor-on-kind` @ `b65df71`; full history kept), published at https://github.com/it255ru/harbor-prod-mirror-on-kind. A 14-node KinD HA Harbor lab that mirrors one specific production stand: Harbor **2.14.3** (chart `1.18.3`), a **Keepalived + HAProxy** Infra LB, external PostgreSQL **15.19** under Patroni + Consul, Redis Sentinel, Garage S3.

**State (2026-09-25):** the plan P0–P6 in `backlog.md` is complete. The stand builds from scratch, `make verify` gives 38 PASS / 0 FAIL, and the failure tests `hack/tests/h41…h48`, `h62` were run on this stack. The parent's full backlog is `git show 7279079:backlog.md`.

Where to start: `backlog.md` (Russian, source of truth: decisions D1–D17, pinned versions, success criteria, the plan, results, carried-over lessons), `CLAUDE.md` (rules, pinned versions, commands, gotchas: read it before changing anything), `README.md` (human runbook with the measured failure behaviour), `docs/stand-topology.md` (nodes, roles, addresses, data, secrets; Russian), `docs/verification-runbook.md` (checks V1–V12 and failure-test procedures P4.1–P4.8 with expected results measured on this stack; Russian).

## Layout

| Path | Role |
|------|------|
| `Makefile` | Cluster lifecycle and install entry points (`make help`) |
| `hack/config/kind-cluster.yaml` | 14-node topology; role label/taint `harbor-ha/role`, leader-election tuning |
| `hack/ha/infra-lb.yaml`, `hack/ha/keepalived/` | Infra LB (P2): DaemonSet on the `lb` nodes, Keepalived VIP + HAProxy TCP passthrough to the Harbor nginx pods; own Keepalived image (`make infra-lb`) |
| `hack/ha/` | Dependencies in namespace `harbor-deps`: `consul.yaml`, `postgres.yaml` + `patroni/` (image build), `redis.yaml`, `haproxy.yaml`, `s3.yaml` + `s3-init.sh` (`make ha-deps`) |
| `hack/install-harbor-ha.sh`, `hack/config/harbor-ha.yaml`, `hack/helm-postrender.py` | Harbor in HA: Secrets, pinned Helm chart, `preStop` post-renderer (`make harbor-ha`) |
| `hack/install.sh` | `make infra-lb`, then `harbor-ha` (`make install`) |
| `hack/deploy-app.sh` | Build/push the demo image, trust Harbor's CA on the node, deploy the app (`make deploy-app`) |
| `hack/tests/` | Failure-test scripts and analyzers: `h41-push-pull.sh`, `h42-kill-during-push.sh`, `h43-rolling-update.sh`, `h44-node-loss.sh`, `h45-app-rollout.sh`, `h46-proxy-cache.sh`, `h47-role-failure.sh`, `h48-node-replace.sh`, `h62-sync-mode.sh` (+ `h4x_analyze.py`) |
| `ansible/` | `verify.yml` + roles `verify_*` (V1..V12), `group_vars/all.yml` (numbers, addresses), `files/s3-access.sh`; run with `make verify` |
| `hack/images.txt`, `hack/image-cache.sh` | Pinned third-party images with node roles; local cache (`~/.cache/harbor-ha`), `make images-save/load/check/status` |
| `hack/add_host.sh` | Add the Harbor hostname to `/etc/hosts` |
| `python-docker-hello-kube/`, `helm-hello-kube/` | Demo app (stdlib `http.server`), Dockerfile, raw manifest and Helm chart |
| `bin/` | Local tools (kind), gitignored |

## Defaults

- Cluster `harbor` → context `kind-harbor`; LB IP `172.20.0.100` (Keepalived VIP) → `core.harbor.domain`; the demo app is a NodePort (`<control-plane IP>:30500`). The subnet must match the Docker `kind` network (`docker network inspect kind`, here `172.20.0.0/16`).
- Harbor admin `admin` / `Harbor12345` (lab default); generated passwords live only in Secrets (`harbor-deps`: `pg-credentials`, `redis-credentials`, `s3-credentials`; `default`: `harbor-ha-*`).
- Demo project / image `core.harbor.domain/python/hello:1.0`, pull secret `harbor`, port 5000; `GET /` → `Hello, Kube! (from <pod>)`, `GET /healthz` → `ok`. The demo app runs on the control-plane node.

## Typical flow

1. `make cluster` → `make ha-deps` → `make infra-lb` → `make add-host` → `make harbor-ha`.
2. Once, by the user (interactive `sudo`): host Docker must trust `core.harbor.domain` (`insecure-registries`); `make deploy-app` checks and prints the exact command if missing.
3. `make deploy-app`, then `make verify` (or the runbook checks by hand) and the failure tests in `hack/tests/`.
4. Cleanup: `make cluster-delete`.

## Conventions

- Follow the phase order in `backlog.md`; record results there; ask before making a new design decision.
- Prefer `make` targets over ad-hoc kind/helm commands; always pin `--version` on Helm installs; pin versions before installing anything new.
- Do not commit secrets, `ca.crt`, `*.tgz` or `bin/`. Never touch the user's `~/.aws`.
- `CLUSTER` / `LB_IP` match `harbor-on-kind` and the parent on purpose (one lab cluster at a time among all three repos, D5): `make cluster-delete` whichever other one is up first.
- Keep `README.md`, `CLAUDE.md` and this file in sync with `Makefile` / `hack/` when pins, topology or the demo app change.
