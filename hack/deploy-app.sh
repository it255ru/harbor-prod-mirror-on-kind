#!/usr/bin/env bash
# Build, push, and deploy the hello-kube demo app after `make install` has put Harbor up.
# Idempotent: safe to re-run (e.g. after editing hello.py) to rebuild/repush/redeploy.

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT="$(cd "$CURDIR/.." && pwd)"
APP_DIR="$ROOT/python-docker-hello-kube"

CLUSTER="${CLUSTER:-harbor}"
HARBOR_HOST="${HARBOR_HOST:-core.harbor.domain}"
LB_IP="${LB_IP:-172.20.0.100}"
HARBOR_USER="admin"
HARBOR_PASSWORD="Harbor12345"
PROJECT="python"
IMAGE="${HARBOR_HOST}/${PROJECT}/hello:1.0"
NODE="${CLUSTER}-control-plane"

echo "==> Checking host Docker trusts ${HARBOR_HOST}"
if ! docker info --format '{{.RegistryConfig.IndexConfigs}}' 2>/dev/null | grep -q "${HARBOR_HOST}"; then
  cat >&2 <<EOF
Host Docker does not trust ${HARBOR_HOST} yet (self-signed cert). Run once, then re-run 'make deploy-app':

  jq '.["insecure-registries"] += ["${HARBOR_HOST}"] | .["insecure-registries"] |= unique' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new >/dev/null
  sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
  sudo systemctl reload docker
EOF
  exit 1
fi

echo "==> Ensuring Harbor project '${PROJECT}' exists"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
  -X POST "https://${HARBOR_HOST}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d "{\"project_name\":\"${PROJECT}\",\"public\":false}")
if [[ "$CODE" != "201" && "$CODE" != "409" ]]; then
  echo "Failed to ensure project '${PROJECT}' (HTTP ${CODE})" >&2
  exit 1
fi

echo "==> docker login ${HARBOR_HOST}"
echo "${HARBOR_PASSWORD}" | docker login "${HARBOR_HOST}" -u "${HARBOR_USER}" --password-stdin

echo "==> Building and pushing ${IMAGE}"
docker build "${APP_DIR}" -t "${IMAGE}"
docker push "${IMAGE}"

echo "==> Trusting Harbor's CA inside KinD node '${NODE}'"
TMP_CA="$(mktemp)"
trap 'rm -f "${TMP_CA}"' EXIT
curl -sk "https://${HARBOR_HOST}/api/v2.0/systeminfo/getcert" -o "${TMP_CA}"
docker cp "${TMP_CA}" "${NODE}:/usr/local/share/ca-certificates/harbor-ca.crt"
docker exec "${NODE}" update-ca-certificates >/dev/null
docker exec "${NODE}" sh -c "grep -q ${HARBOR_HOST} /etc/hosts || echo '${LB_IP} ${HARBOR_HOST}' >> /etc/hosts"
docker exec "${NODE}" systemctl restart containerd

echo "==> Ensuring pull secret 'harbor'"
kubectl create secret docker-registry harbor \
  --docker-server="${HARBOR_HOST}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASSWORD}" \
  --docker-email=root@testlab.local \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> Deploying demo app"
kubectl apply -f "${APP_DIR}/deployment.yml"
kubectl rollout restart deployment/hello-deployment >/dev/null
kubectl wait --for=condition=ready pod -l app=hello --timeout=90s

NODE_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${NODE}" 2>/dev/null || true)"
echo
echo "==> Demo app ready: http://${NODE_IP:-<control-plane IP>}:30500  (NodePort of hello-service; GET /healthz for the probe endpoint)"
