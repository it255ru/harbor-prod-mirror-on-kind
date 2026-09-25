#!/usr/bin/env bash
# H4.11 (backlog): loss of the (only) control-plane node while the stand is under load, and its return.
#
# usage: hack/tests/h51-control-plane-loss.sh
# env:   HOLD (seconds to keep the control-plane down, default 300), WORKDIR, HARBOR_HOST, HARBOR_AUTH, CLUSTER (default harbor)
#
# kind has ONE control-plane container and etcd lives inside it: while it is down nothing can be scheduled, rescheduled or changed,
# and Service endpoints are frozen; what is already running keeps running. The test checks that the DATA PATH keeps working without
# the Kubernetes API (VIP -> HAProxy -> nginx -> core -> registry -> S3, PostgreSQL through Patroni/Consul, Redis through Sentinel:
# none of them needs the API) and that the cluster is manageable again after `docker start`. It does NOT destroy the control-plane:
# a PERMANENT loss cannot be repaired in place (no etcd backup is taken), the recovery is a rebuild of the cluster.
#
# Load (as in h44, no client retries in curl): manifest every ~0.1 s, blob every ~0.4 s, docker pull in a loop, docker push every ~3 s.
# Every 30 s of the outage it also records: kubectl answers?  https through the VIP?  demo app (runs on the control-plane node)?
set -uo pipefail
HOLD=${HOLD:-300}; CLUSTER=${CLUSTER:-harbor}; CP=$CLUSTER-control-plane
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; API=https://$HOST/api/v2.0
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
IMG=$HOST/python/hello:1.0
now_ms() { date +%s%3N; }
ev() { echo "$(now_ms) $1" >> events.log; echo "   [$(date +%T)] $1"; }
wait_for() { local what=$1 to=$2; shift 2; local t=$SECONDS; while ! "$@" >/dev/null 2>&1; do [ $((SECONDS-t)) -gt "$to" ] && { echo "   !! timeout ($to s) waiting for: $what"; return 1; }; sleep 2; done; }
api_ok() { timeout 8 kubectl get --raw /readyz >/dev/null 2>&1; }
ready_all() { [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready')" = 0 ] && [ "$(kubectl get deploy --no-headers 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')" = "2/2 " ] && [ "$(kubectl get sts harbor-trivy -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 2 ]; }
cp_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CP" 2>/dev/null; }
restart_snapshot() { kubectl get pods -A -o custom-columns=P:.metadata.namespace,N:.metadata.name,R:.status.containerStatuses[*].restartCount --no-headers 2>/dev/null | awk '{n=0; for(i=3;i<=NF;i++) if ($i ~ /^[0-9]+$/) n+=$i; print $1"/"$2, n}' | sort; }

echo "== precondition"
api_ok && ready_all || { echo "!! the stand is not healthy (API, nodes Ready, Deployments 2/2)"; exit 1; }
CP_IP0=$(cp_ip); NODEPORT="http://$CP_IP0:30500/"
echo "   control-plane $CP $CP_IP0; load: $(cut -d' ' -f1-3 /proc/loadavg); demo app: $(curl -s -m 5 "$NODEPORT" | cut -c1-40)"
restart_snapshot > restarts.before
MANIFEST=$(curl -sk -u "$AUTH" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://$HOST/v2/python/hello/manifests/1.0")
BLOB=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(max(d['layers'],key=lambda l:l['size'])['digest'])")
: > manifest.log; : > blob.log; : > pull.log; : > push.log; : > events.log; : > pull-errors.log; : > outage.log
STOP=$W/stop; rm -f "$STOP"
cleanup() {
  touch "$STOP"; wait 2>/dev/null
  [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null)" = true ] || { echo "   (cleanup) starting $CP"; docker start "$CP" >/dev/null 2>&1; }
  wait_for "API" 240 api_ok && curl -sk -o /dev/null -u "$AUTH" -X DELETE "$API/projects/python/repositories/h51"
  for i in $(seq 1 400); do docker rmi "$HOST/python/h51:$i" >/dev/null 2>&1 || break; done; docker rmi "$HOST/python/h51base:1" >/dev/null 2>&1
}
trap cleanup EXIT
prober() { local name=$1 url=$2 iv=$3
  while [ ! -e "$STOP" ]; do r=$(curl -sk -u "$AUTH" -o /dev/null -w "%{http_code} %{time_total}" -m 30 "$url" 2>/dev/null); rc=$?
    echo "$(now_ms) ${r:-000 0} rc=$rc" >> "$name.log"; sleep "$iv"; done; }
puller() { while [ ! -e "$STOP" ]; do docker rmi "$IMG" >/dev/null 2>&1; s=$(now_ms); out=$(timeout 120 docker pull "$IMG" 2>&1); rc=$?
    echo "$s $(now_ms) rc=$rc" >> pull.log; [ $rc -ne 0 ] && echo "$s FAIL: $(echo "$out" | tail -1)" >> pull-errors.log; done; }
docker tag "$IMG" "$HOST/python/h51base:1" 2>/dev/null
pusher() { i=0; while [ ! -e "$STOP" ]; do i=$((i+1)); s=$(now_ms)
    if docker tag "$HOST/python/h51base:1" "$HOST/python/h51:$i" 2>/dev/null; then timeout 120 docker push "$HOST/python/h51:$i" >/dev/null 2>&1; rc=$?; else rc=99; fi
    echo "$s $(now_ms) rc=$rc n=$i" >> push.log; sleep 3; done; }
prober manifest "https://$HOST/v2/python/hello/manifests/1.0" 0.1 &
prober blob "https://$HOST/v2/python/hello/blobs/$BLOB" 0.4 &
puller & pusher &
sleep 12; ev baseline-end

echo "== KILL $CP"
docker kill "$CP" >/dev/null; ev node-down
T=$SECONDS
while [ $((SECONDS-T)) -lt "$HOLD" ]; do
  sleep 30
  a=$(api_ok && echo yes || echo NO); v=$(curl -sk -o /dev/null -w '%{http_code}' -m 8 "https://$HOST/"); d=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$NODEPORT")
  echo "   +$((SECONDS-T)) s: kubectl answers: $a   https via VIP: $v   demo app (on the control-plane): $d" | tee -a outage.log
done
ev degraded-steady

echo "== START $CP"
docker start "$CP" >/dev/null; ev node-up
CP_IP1=$(cp_ip); echo "   control-plane IP: before $CP_IP0, after $CP_IP1"
T=$SECONDS; wait_for "API" 300 api_ok; ev api-back; echo "   API answers $((SECONDS-T)) s after the start"
T=$SECONDS; wait_for "nodes Ready" 300 bash -c "[ \"\$(kubectl get nodes --no-headers | grep -vc ' Ready')\" = 0 ]"; ev node-ready; echo "   all nodes Ready $((SECONDS-T)) s after the API is back"
T=$SECONDS; wait_for "everything 2/2" 420 ready_all; ev recovered; echo "   Deployments 2/2 and Trivy 2/2 $((SECONDS-T)) s later"
sleep 30; ev settled
touch "$STOP"; wait

echo "== after"
restart_snapshot > restarts.after
echo "   container restarts during the test (pod: before -> after):"
join -o 0,1.2,2.2 restarts.before restarts.after 2>/dev/null | awk '$3>$2{printf "     %s: %s -> %s\n", $1,$2,$3; f=1} END{if(!f) print "     none"}'
echo "   demo app: $(curl -s -m 5 "http://$(cp_ip):30500/" | cut -c1-40)"
echo "   pods not Running: $(kubectl get pods -A --no-headers | grep -vcE 'Running|Completed')"
echo "== analysis"
python3 "$HERE/h44_analyze.py" "$W"
echo "logs in $W"
