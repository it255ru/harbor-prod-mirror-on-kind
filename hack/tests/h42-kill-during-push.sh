#!/usr/bin/env bash
# H4.2 (backlog): force-kill the Harbor pod that is receiving a large push, while the push is running,
# and check that the client retries and the push completes with intact data.
#
# usage: hack/tests/h42-kill-during-push.sh <registry|core> <container> <tag>
#   registry -> container "registry", core -> container "core"
# env:   LAYERS (default 2)   SIZE_MB (default 200)   RATE (default 80mbit)   THRESHOLD (bytes, default 2000000)
#
# How it works
#   * builds an image with random (incompressible) layers on top of python/hello:1.0;
#   * throttles egress of the app nodes with tc (registry -> S3), so the upload lasts long enough
#     to be caught, and always removes the throttle on exit;
#   * finds the pod that is actually receiving the upload by the growth of its eth0 rx counter and
#     deletes it with --force --grace-period=0 (a crash, not a graceful stop);
#   * waits for `docker push` to finish, prints the client retries and the status codes of the Harbor nginx proxy;
#   * cleans up by DIGEST (never by tag: a shared tag would delete other tags of the same artifact,
#     e.g. python/hello:1.0).
#
# Do NOT raise SIZE_MB/LAYERS much: everything shares one host disk, and gigabytes of writes made the
# apiserver stall, controller-manager/scheduler lose their lease and Sentinel fail over (H4.2).
# The script waits for the host load to drop before it starts pushing.
set -uo pipefail
COMP=${1:?registry|core}; CTR=${2:?container}; TAG=${3:?tag}
LAYERS=${LAYERS:-2}; SIZE_MB=${SIZE_MB:-200}
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W" || exit 1
IMG=$HOST/python/hello:$TAG

rx() { kubectl exec "$1" -c "$CTR" -- grep eth0 /proc/net/dev 2>/dev/null | tr -d '\r' | awk '{print $2}'; }

THROTTLE_NODES="harbor-worker harbor-worker2"; THRESHOLD=${THRESHOLD:-2000000}
throttle_on()  { for n in $THROTTLE_NODES; do docker exec $n tc qdisc replace dev eth0 root tbf rate "${RATE:-80mbit}" burst 64kb latency 400ms; done; echo "== throttle ON (${RATE:-80mbit}) on $THROTTLE_NODES"; }
throttle_off() { for n in $THROTTLE_NODES; do docker exec $n tc qdisc del dev eth0 root 2>/dev/null; done; echo "== throttle OFF"; }
cleanup() {
  throttle_off
  D=$(grep -oE "digest: sha256:[0-9a-f]{64}" push.log 2>/dev/null | head -1 | cut -d' ' -f2)
  if [ -n "$D" ]; then
    echo "== cleanup: delete artifact by digest $D: $(curl -sk -o /dev/null -w '%{http_code}' -u "$AUTH" -X DELETE "https://$HOST/api/v2.0/projects/python/repositories/hello/artifacts/$D")"
  fi
  docker rmi "$IMG" >/dev/null 2>&1
}
trap cleanup EXIT

{
  echo "FROM $HOST/python/hello:1.0"
  for i in $(seq 1 "$LAYERS"); do echo "RUN dd if=/dev/urandom of=/blob-$TAG-$i bs=1M count=$SIZE_MB 2>/dev/null"; done
} > Dockerfile
echo "== build $IMG ($LAYERS layers x $SIZE_MB MB random)"
docker build -q -t "$IMG" . >/dev/null || exit 1

# the build saturates the shared disk: let the stand settle first, otherwise Redis/Sentinel and the
# control plane flap and the test measures the wrong thing
for _ in $(seq 1 30); do awk 'BEGIN{exit !('"$(cut -d' ' -f1 /proc/loadavg)"' < 3)}' && break; sleep 10; done
kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster | head -1
echo "load before push: $(cut -d' ' -f1-3 /proc/loadavg)"

PODS=($(kubectl get pods -l component=$COMP -o name))
echo "== replicas before: ${PODS[*]}"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -A prev
for p in "${PODS[@]}"; do prev[$p]=$(rx "$p"); done

throttle_on
echo "== start push"
: > push.log
( timeout 900 docker push "$IMG" > push.log 2>&1; echo "exit=$?" >> push.log ) &
PUSHPID=$!

VICTIM=""
for _ in $(seq 1 80); do
  for p in "${PODS[@]}"; do
    now=$(rx "$p"); d=$(( now - prev[$p] )); prev[$p]=$now
    if [ "$d" -gt "$THRESHOLD" ]; then VICTIM=$p; echo "== active pod: $p (rx +$((d/1000000)) MB in one poll) at $(date -u +%T.%N | cut -c1-12)"; break 2; fi
  done
done
if [ -z "$VICTIM" ]; then echo "!! no active pod detected (push too fast or finished)"; wait $PUSHPID; tail -3 push.log; exit 3; fi

echo "== FORCE DELETE $VICTIM at $(date -u +%T.%N | cut -c1-12)"
kubectl delete "$VICTIM" --grace-period=0 --force 2>&1 | tail -1
wait $PUSHPID
echo "== push finished at $(date -u +%T.%N | cut -c1-12)   load after: $(cut -d' ' -f1-3 /proc/loadavg)"
grep -E "Retrying|retry|error|denied|unauthorized|digest:|exit=" push.log | sed 's/[0-9]* seconds\?/N s/' | sort | uniq -c | head -12

echo "== nginx (Harbor proxy) status codes for /v2/ since T0 (both replicas)"
for c in $(kubectl get pods -l app=harbor,component=nginx -o name); do kubectl logs "$c" --since-time="$T0"; done \
  | grep -E '"(PUT|PATCH|POST|GET|HEAD) /v2/' | awk '{for(i=1;i<=NF;i++) if ($i ~ /^"(PUT|PATCH|POST|GET|HEAD)$/) {m=substr($i,2); print m, $(i+3)}}' \
  | sort | uniq -c | sort -k2,2 -k3,3n

# integrity: pull the image back and compare the digest with the pushed one
D=$(grep -oE "digest: sha256:[0-9a-f]{64}" push.log | head -1 | cut -d' ' -f2)
docker rmi "$IMG" >/dev/null 2>&1
echo "== pull back: $(docker pull "$IMG" 2>&1 | grep -E '^Digest')   (pushed: $D)"
