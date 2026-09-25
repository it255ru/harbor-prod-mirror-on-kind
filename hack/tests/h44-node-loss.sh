#!/usr/bin/env bash
# H4.4 (backlog): lose a worker node (an `app` node) while clients pull continuously; check that the
# service keeps answering on the surviving node, and that everything comes back when the node returns.
#
# usage: hack/tests/h44-node-loss.sh [node]              (default: harbor-worker2)
# env:   EVICT_WAIT=1  keep the node down until Kubernetes evicts its pods (~5 min, default) instead of
#                      stopping after the degraded phase;  WORKDIR, HARBOR_HOST, HARBOR_AUTH
#
# The node "dies" with `docker kill` (no graceful shutdown: kubelet and containerd vanish at once) and
# is brought back with `docker start`. Load, through the Infra LB and without client retries in curl:
#   manifest GET every ~0.1 s, 13 MB blob GET every ~0.4 s, docker rmi + docker pull back to back.
# Timeline events are written to events.log and analysed by hack/tests/h44_analyze.py.
set -uo pipefail
NODE=${1:-harbor-worker2}; EVICT_WAIT=${EVICT_WAIT:-1}
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
IMG=$HOST/python/hello:1.0
now_ms() { date +%s%3N; }
ev() { echo "$(now_ms) $1" >> events.log; echo "   [$(date +%T)] $1"; }
DEPLOYS="harbor-core harbor-portal harbor-registry harbor-jobservice"

ready_all() { for d in $DEPLOYS; do r=$(kubectl get deploy $d -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null); [ "$r" = "2/2" ] || return 1; done; }
wait_for() {  # description timeout-s command...
  local what=$1 to=$2; shift 2; local t=$SECONDS
  while ! "$@" >/dev/null 2>&1; do [ $((SECONDS-t)) -gt "$to" ] && { echo "   !! timeout waiting for: $what"; return 1; }; sleep 2; done
}
node_ready()    { [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
node_notready() { [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" != "True" ]; }
ep_clean() {  # every Harbor Service has exactly one ready endpoint (the survivor)
  for s in harbor-core harbor-portal harbor-registry; do
    n=$(kubectl get endpoints $s -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w); [ "$n" = 1 ] || return 1
  done
}
evicted() { [ "$(kubectl get pods --no-headers 2>/dev/null | grep -E 'harbor-(core|portal|registry|jobservice)' | grep -c Pending)" -ge 1 ]; }

echo "== precondition"
ready_all || { echo "!! Harbor deployments are not 2/2"; exit 1; }
node_ready || { echo "!! $NODE is not Ready"; exit 1; }
echo "victim: $NODE  pods on it:"; kubectl get pods -o wide --no-headers | awk -v n="$NODE" '$7==n{print "   "$1}'
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"
MANIFEST=$(curl -sk -u "$AUTH" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://$HOST/v2/python/hello/manifests/1.0")
BLOB=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(max(d['layers'],key=lambda l:l['size'])['digest'])")

: > manifest.log; : > blob.log; : > pull.log; : > events.log; : > pull-errors.log
STOP=$W/stop; rm -f "$STOP"
prober() {
  local name=$1 url=$2 iv=$3
  while [ ! -e "$STOP" ]; do
    r=$(curl -sk -u "$AUTH" -o /dev/null -w "%{http_code} %{time_total}" -m 30 "$url" 2>/dev/null); rc=$?
    echo "$(now_ms) ${r:-000 0} rc=$rc" >> "$name.log"; sleep "$iv"
  done
}
puller() {
  while [ ! -e "$STOP" ]; do
    docker rmi "$IMG" >/dev/null 2>&1
    s=$(now_ms); out=$(timeout 120 docker pull "$IMG" 2>&1); rc=$?
    echo "$s $(now_ms) rc=$rc" >> pull.log
    [ $rc -ne 0 ] && echo "$s FAIL: $(echo "$out" | tail -1)" >> pull-errors.log
  done
}
prober manifest "https://$HOST/v2/python/hello/manifests/1.0" 0.1 &
prober blob "https://$HOST/v2/python/hello/blobs/$BLOB" 0.4 &
puller &
sleep 10; ev baseline-end

echo "== KILL $NODE"
docker kill "$NODE" >/dev/null; ev node-down
T=$SECONDS; wait_for "node NotReady" 180 node_notready; ev node-notready; echo "   NotReady after $((SECONDS-T)) s"
T=$SECONDS; wait_for "endpoints cleaned" 120 ep_clean; ev endpoints-updated; echo "   endpoints cleaned $((SECONDS-T)) s after NotReady"
sleep 60; ev degraded-steady
kubectl get pods -o wide --no-headers | grep -E "harbor-(core|portal|registry|jobservice|trivy)" | awk '{print "   "$1,$2,$3,$7}'
if [ "$EVICT_WAIT" = 1 ]; then
  T=$SECONDS; wait_for "eviction (replacement pods Pending)" 420 evicted; ev evicted; echo "   evicted after $((SECONDS-T)) s of waiting"
  kubectl get pods -o wide --no-headers | grep -E "harbor-(core|portal|registry|jobservice|trivy)" | awk '{print "   "$1,$2,$3,$7}'
  kubectl get pods --no-headers | grep Pending | head -1 >/dev/null && kubectl describe pod $(kubectl get pods --no-headers | awk '/Pending/{print $1; exit}') | grep -E "FailedScheduling" | head -1 | cut -c1-260
  sleep 30
fi

echo "== START $NODE"
docker start "$NODE" >/dev/null; ev node-up
T=$SECONDS; wait_for "node Ready" 300 node_ready; ev node-ready; echo "   Ready after $((SECONDS-T)) s"
T=$SECONDS; wait_for "deployments 2/2" 420 ready_all; ev recovered; echo "   all Deployments 2/2 after $((SECONDS-T)) s"
wait_for "trivy 2/2" 240 bash -c "[ \"\$(kubectl get sts harbor-trivy -o jsonpath={.status.readyReplicas})\" = 2 ]"
sleep 20; ev settled
touch "$STOP"; wait

echo "== final state"
kubectl get pods -o wide --no-headers | grep -E "harbor-(core|portal|registry|jobservice|trivy)" | grep -v Terminating | awk '{print "   "$1,$2,$3,$7}'
echo "== analysis"
python3 "$HERE/h44_analyze.py" "$W"
echo "logs in $W"
