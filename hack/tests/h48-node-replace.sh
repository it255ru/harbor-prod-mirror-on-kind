#!/usr/bin/env bash
# H4.8 (backlog): PERMANENT loss of an `app` node and its replacement, while clients pull continuously.
#
# usage: hack/tests/h48-node-replace.sh [node]          (default: harbor-worker2, the node with Trivy and its local PVC)
# env:   CLUSTER (default harbor), WORKDIR, HARBOR_HOST, HARBOR_AUTH, KIND (default ./bin/kind)
#
# What it does (the node is NEVER started again):
#   1. saves the node's kubeadm config and container settings, `docker kill`s the node, waits for NotReady and for the
#      Harbor endpoints to drop it (the degraded phase, as in h44);
#   2. the administrator's reaction: `kubectl delete node` and removal of the dead container;
#   3. a replacement node is built by hand (kind cannot add a node to a running cluster): a new kindest/node container with
#      the same name, role label and taint, joined with `kubeadm join` using the config the dead node had (fresh token);
#   4. the cached images of the role are loaded into it (hack/image-cache.sh load), Pending pods must schedule, Deployments
#      must be 2/2 again; the PVC of the Trivy replica that lived on the dead node (local-path, bound to it) is checked and, if
#      the pod is stuck, reset.
# Load is the same as in h44 (manifest, blob, docker pull, no client retries in curl); the analysis is h44_analyze.py.
set -uo pipefail
NODE=${1:-harbor-worker2}; CLUSTER=${CLUSTER:-harbor}
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
KIND="${KIND:-$ROOT/bin/kind}"; [ -x "$KIND" ] || KIND=kind
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
IMG=$HOST/python/hello:1.0
CP=$CLUSTER-control-plane
now_ms() { date +%s%3N; }
ev() { echo "$(now_ms) $1" >> events.log; echo "   [$(date +%T)] $1"; }
DEPLOYS="harbor-nginx harbor-core harbor-portal harbor-registry harbor-jobservice"

ready_all() { for d in $DEPLOYS; do r=$(kubectl get deploy $d -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null); [ "$r" = "2/2" ] || return 1; done; }
wait_for() { local what=$1 to=$2; shift 2; local t=$SECONDS
  while ! "$@" >/dev/null 2>&1; do [ $((SECONDS-t)) -gt "$to" ] && { echo "   !! timeout waiting for: $what"; return 1; }; sleep 2; done; }
node_ready()    { [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
node_notready() { [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" != "True" ]; }
ep_clean() { for s in harbor-core harbor-portal harbor-registry; do
    n=$(kubectl get endpoints $s -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w); [ "$n" = 1 ] || return 1; done; }
pods_here() { kubectl get pods -o wide --no-headers | awk -v n="$NODE" '$7==n{print "   "$1,$3}'; }

echo "== precondition"
ready_all || { echo "!! Harbor deployments are not 2/2"; exit 1; }
node_ready || { echo "!! $NODE is not Ready"; exit 1; }
ROLE=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.harbor-ha/role}')
[ -n "$ROLE" ] || { echo "!! $NODE has no harbor-ha/role label"; exit 1; }
NODE_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$NODE")
docker exec "$NODE" cat /kind/kubeadm.conf > kubeadm.conf || { echo "!! cannot read /kind/kubeadm.conf"; exit 1; }
echo "victim: $NODE (role $ROLE, image $NODE_IMAGE)  pods on it:"; pods_here
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"
MANIFEST=$(curl -sk -u "$AUTH" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://$HOST/v2/python/hello/manifests/1.0")
BLOB=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(max(d['layers'],key=lambda l:l['size'])['digest'])")

: > manifest.log; : > blob.log; : > pull.log; : > events.log; : > pull-errors.log
STOP=$W/stop; rm -f "$STOP"
cleanup() { touch "$STOP"; wait 2>/dev/null; }
trap cleanup EXIT
prober() { local name=$1 url=$2 iv=$3
  while [ ! -e "$STOP" ]; do
    r=$(curl -sk -u "$AUTH" -o /dev/null -w "%{http_code} %{time_total}" -m 30 "$url" 2>/dev/null); rc=$?
    echo "$(now_ms) ${r:-000 0} rc=$rc" >> "$name.log"; sleep "$iv"
  done; }
puller() { while [ ! -e "$STOP" ]; do docker rmi "$IMG" >/dev/null 2>&1
    s=$(now_ms); out=$(timeout 120 docker pull "$IMG" 2>&1); rc=$?
    echo "$s $(now_ms) rc=$rc" >> pull.log; [ $rc -ne 0 ] && echo "$s FAIL: $(echo "$out" | tail -1)" >> pull-errors.log
  done; }
prober manifest "https://$HOST/v2/python/hello/manifests/1.0" 0.1 &
prober blob "https://$HOST/v2/python/hello/blobs/$BLOB" 0.4 &
puller &
sleep 10; ev baseline-end

echo "== KILL $NODE (it will not come back)"
docker kill "$NODE" >/dev/null; ev node-down
T=$SECONDS; wait_for "node NotReady" 180 node_notready; ev node-notready; echo "   NotReady after $((SECONDS-T)) s"
T=$SECONDS; wait_for "endpoints cleaned" 120 ep_clean; ev endpoints-updated; echo "   endpoints cleaned $((SECONDS-T)) s after NotReady"
sleep 60; ev degraded-steady
echo "   state with one app node (before any action):"
kubectl get pods -o wide --no-headers | grep -E "harbor-(nginx|core|portal|registry|jobservice|trivy)" | awk '{print "     "$1,$2,$3,$7}'

echo "== administrator: delete the node object and the dead container"
kubectl delete node "$NODE" --wait=true >/dev/null 2>&1; docker rm -f "$NODE" >/dev/null 2>&1; ev node-deleted
sleep 15
echo "   pods after 'kubectl delete node':"
kubectl get pods -o wide --no-headers | grep -E "harbor-(nginx|core|portal|registry|jobservice|trivy)" | awk '{print "     "$1,$2,$3,$7}'

echo "== replacement node $NODE (role $ROLE)"
TOKEN=$(docker exec "$CP" kubeadm token create --ttl 15m)
docker run -d --name "$NODE" --hostname "$NODE" --network kind --privileged \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable \
  --tmpfs /tmp --tmpfs /run -v /lib/modules:/lib/modules:ro -v /var --restart on-failure:1 \
  --label io.x-k8s.kind.cluster="$CLUSTER" --label io.x-k8s.kind.role=worker -e KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER \
  "$NODE_IMAGE" >/dev/null || { echo "!! cannot start the replacement container"; exit 1; }
ev node-up
wait_for "containerd in the new node" 90 docker exec "$NODE" systemctl is-active containerd || exit 1
NEWIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NODE")
sed -e "s|node-ip: .*|node-ip: $NEWIP|" -e "s|token: .*|token: $TOKEN|" kubeadm.conf > kubeadm.new.conf
docker cp kubeadm.new.conf "$NODE:/kind/kubeadm.conf"
docker exec "$NODE" kubeadm join --config /kind/kubeadm.conf --skip-phases=preflight > join.log 2>&1 || { echo "!! kubeadm join failed:"; tail -5 join.log; exit 1; }
T=$SECONDS; wait_for "node Ready" 300 node_ready; ev node-ready; echo "   new node $NEWIP Ready after $((SECONDS-T)) s"
echo "   labels/taints: $(kubectl get node $NODE -o jsonpath='{.metadata.labels.harbor-ha/role}') / $(kubectl get node $NODE -o jsonpath='{.spec.taints[*].key}')"

echo "== load the cached images of the role into the new node"
CLUSTER=$CLUSTER KIND=$KIND "$ROOT/hack/image-cache.sh" load 2>&1 | grep -E "loaded on|FAILED" | head -20
T=$SECONDS; wait_for "deployments 2/2" 420 ready_all; ev recovered; echo "   all Deployments 2/2 after $((SECONDS-T)) s"

echo "== Trivy (StatefulSet, 2 replicas, each with a node-local PVC)"
sleep 20
kubectl get pods -l component=trivy -o wide --no-headers 2>/dev/null | awk '{print "   "$1,$2,$3,$7}'
for i in 0 1; do pod=harbor-trivy-$i
  if ! kubectl wait --for=condition=ready pod/$pod --timeout=20s >/dev/null 2>&1; then
    echo "   $pod is not Ready: $(kubectl get pod $pod -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null | cut -c1-220)"
    echo "   -> reset: its local-path PVC (bound to the dead node) and the pod are deleted, Trivy re-downloads its database"
    kubectl delete pvc data-$pod --wait=false >/dev/null 2>&1; kubectl delete pod $pod --wait=true >/dev/null 2>&1
    wait_for "$pod ready" 300 kubectl wait --for=condition=ready pod/$pod --timeout=5s; ev trivy-reset
    kubectl get pod $pod -o wide --no-headers | awk '{print "   "$1,$2,$3,$7}'
  fi
done
sleep 20; ev settled
touch "$STOP"; wait

echo "== final state"
kubectl get nodes -L harbor-ha/role --no-headers | awk '{print "   "$1,$2,$6}' | grep -E "app|control"
kubectl get pods -o wide --no-headers | grep -E "harbor-(nginx|core|portal|registry|jobservice|trivy)" | grep -v Terminating | awk '{print "   "$1,$2,$3,$7}'
echo "== analysis"
python3 "$HERE/h44_analyze.py" "$W"
echo "logs in $W"
