#!/usr/bin/env bash
# Harbor in HA mode (backlog H3): creates the Secrets Harbor needs in the `default` namespace,
# then installs the pinned chart with hack/config/harbor-ha.yaml.
# The chart resolves existing Secrets with `lookup` at render time, so they must exist first.
# DRY_RUN=1 renders against the cluster (helm --dry-run=server) without installing.

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DEPS_NS=harbor-deps
NS=default

src() { kubectl -n "$DEPS_NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

for s in pg-credentials redis-credentials s3-credentials; do
  kubectl -n "$DEPS_NS" get secret "$s" >/dev/null 2>&1 || { echo "Secret $DEPS_NS/$s not found - run 'make ha-deps' first" >&2; exit 1; }
done

# One Secret with everything the chart reads via existingSecret (key names are fixed by the chart).
# Created once and never regenerated: rotating secretKey/core secret would break stored data and
# running replicas. To reset, delete the Secret together with the Harbor release and its data.
if ! kubectl -n "$NS" get secret harbor-ha-secrets >/dev/null 2>&1; then
  echo "==> Creating Secret $NS/harbor-ha-secrets"
  kubectl -n "$NS" create secret generic harbor-ha-secrets \
    --from-literal=password="$(src pg-credentials harbor)" \
    --from-literal=REDIS_PASSWORD="$(src redis-credentials password)" \
    --from-literal=secret="$(openssl rand -hex 8)" \
    --from-literal=CSRF_KEY="$(openssl rand -hex 16)" \
    --from-literal=JOBSERVICE_SECRET="$(openssl rand -hex 8)" \
    --from-literal=REGISTRY_HTTP_SECRET="$(openssl rand -hex 8)" \
    --from-literal=secretKey="$(openssl rand -hex 8)"
fi

# S3 keys get their own Secret: the chart loads it whole into the registry containers (envFrom),
# so it must not contain anything else.
if ! kubectl -n "$NS" get secret harbor-ha-s3 >/dev/null 2>&1; then
  echo "==> Creating Secret $NS/harbor-ha-s3"
  kubectl -n "$NS" create secret generic harbor-ha-s3 \
    --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$(src s3-credentials harbor-access-key)" \
    --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$(src s3-credentials harbor-secret-key)"
fi

# Token signing key/cert shared by all core replicas (otherwise the chart generates a new pair on every upgrade).
if ! kubectl -n "$NS" get secret harbor-ha-token >/dev/null 2>&1; then
  echo "==> Creating Secret $NS/harbor-ha-token"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # Harbor core parses the key as PKCS#1 ("BEGIN RSA PRIVATE KEY"); `openssl req -newkey` and plain
  # `genrsa` on OpenSSL 3 emit PKCS#8, which core rejects ("unable to get PrivateKey from PEM type").
  openssl genrsa -traditional -out "$tmp/tls.key" 2048 2>/dev/null
  openssl req -x509 -new -key "$tmp/tls.key" -days 3650 -subj "/CN=harbor-token-ca" -out "$tmp/tls.crt"
  kubectl -n "$NS" create secret tls harbor-ha-token --cert="$tmp/tls.crt" --key="$tmp/tls.key"
fi

# Stable TLS certificate and CA for the ingress. With `certSource: auto` the chart generates a NEW
# self-signed CA on every `helm upgrade`, so everything that trusts it (containerd on the nodes, helm
# --ca-file, ...) silently breaks after an upgrade: new image pulls fail with "x509: certificate signed by
# unknown authority" (found in H4.5). A CA created once here survives upgrades. The Secret also carries
# ca.crt, which Harbor serves at /api/v2.0/systeminfo/getcert (values: caSecretName).
HOST_NAME="${HARBOR_HOST:-core.harbor.domain}"
if ! kubectl -n "$NS" get secret harbor-ha-ingress-tls >/dev/null 2>&1; then
  echo "==> Creating Secret $NS/harbor-ha-ingress-tls (CA + certificate for $HOST_NAME, 10 years)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=harbor-ca" \
    -addext "basicConstraints=critical,CA:TRUE" -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$HOST_NAME" -keyout "$tmp/tls.key" -out "$tmp/tls.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$HOST_NAME" > "$tmp/ext.cnf"
  openssl x509 -req -in "$tmp/tls.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial -days 3650 \
    -extfile "$tmp/ext.cnf" -out "$tmp/tls.crt" 2>/dev/null
  kubectl -n "$NS" create secret generic harbor-ha-ingress-tls --type=kubernetes.io/tls \
    --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" --from-file=ca.crt="$tmp/ca.crt"
fi

# The chart archive cached by `make images-save` is preferred over the repository.
HARBOR_CHART="${IMAGE_CACHE:-$HOME/.cache/harbor-ha}/charts/harbor-1.18.3.tgz"
if [ ! -f "$HARBOR_CHART" ]; then
  helm repo add harbor https://helm.goharbor.io
  helm repo update harbor
  HARBOR_CHART=harbor/harbor
fi
# The post-renderer adds a preStop sleep to core/registry/portal so rolling updates do not drop requests
# (see hack/helm-postrender.py; needs python3 + PyYAML).
helm upgrade -i harbor "$HARBOR_CHART" --version 1.18.3 -f "$CURDIR/config/harbor-ha.yaml" \
  --post-renderer "$CURDIR/helm-postrender.py" \
  ${DRY_RUN:+--dry-run=server}
