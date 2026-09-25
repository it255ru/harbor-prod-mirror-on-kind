#!/usr/bin/env bash
# H4.7 (backlog): lose the node of one role of the scheme while the stand is under load.
#
# usage: hack/tests/h47-role-failure.sh <lb|pg|redis|consul>
# env:   HOLD (seconds to keep the node down after the failover is detected, default 45), WORKDIR,
#        HARBOR_HOST, HARBOR_AUTH
#
# Victim node:
#   lb     the lb node that currently ANNOUNCES the Infra LB address (holder of the Keepalived VIP 172.20.0.100): it carries
#          one infra-lb pod (Keepalived MASTER + HAProxy) and one harbor-lb HAProxy
#   pg     the node of the current Patroni leader        (Patroni must promote the replica through Consul)
#   redis  the node of the current Valkey master         (Sentinel must promote a replica)
#   consul the node of the current Consul raft leader    (a new leader must be elected, Patroni must not fail over)
# The node is killed with `docker kill` (no graceful shutdown) and brought back with `docker start`.
#
# Load, all in parallel, no client retries where noted:
#   manifest / blob   GET through the Infra LB every ~0.1 s / ~0.4 s       (curl, no retries)
#   pull              docker rmi + docker pull python/hello:1.0 in a loop  (real client)
#   push              docker push of python/h47:<n> every ~3 s             (writes to PostgreSQL, Redis and S3)
#   pgw               INSERT into h47_probe through harbor-lb:5432 ~4/s    (pod; acknowledged ids are checked afterwards)
#   redisw            INCR h47:counter through harbor-lb:6379 ~4/s          (pod; acknowledged values are checked afterwards)
# At the end the acknowledged writes are compared with what the databases hold (lost acknowledged writes), and
# the analysis (hack/tests/h47_analyze.py) prints errors and outage windows per phase.
set -uo pipefail
ROLE=${1:?usage: h47-role-failure.sh <lb|pg|redis|consul>}
HOLD=${HOLD:-45}
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
API=https://$HOST/api/v2.0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W" || exit 1
NS=harbor-deps; IMG=$HOST/python/hello:1.0
now_ms() { date +%s%3N; }
ev() { echo "$(now_ms) $1" >> events.log; echo "   [$(date +%T)] $1"; }
PGI=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
VKI=valkey/valkey:9.0.6-alpine3.24@sha256:187679e3bd4036959631e3f03983ab2ba503ab21e6fd0454d508e909db2ee989
OV='{"spec":{"nodeSelector":{"harbor-ha/role":"app"},"tolerations":[{"key":"harbor-ha/role","operator":"Equal","value":"app","effect":"NoSchedule"}]}}'
sec() { kubectl -n $NS get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

# ---------- helpers to find roles
pg_leader()     { kubectl -n $NS exec pg-0 -c patroni -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null | python3 -c "import sys,json; print(next((m['Member'] for m in json.load(sys.stdin) if m['Role']=='Leader'),''))" 2>/dev/null \
                  || kubectl -n $NS exec pg-0 -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null | python3 -c "import sys,json; print(next((m['Member'] for m in json.load(sys.stdin) if m['Role']=='Leader'),''))" 2>/dev/null; }
pg_leader_from() { kubectl -n $NS exec "$1" -- curl -s -m 3 http://consul.$NS:8500/v1/kv/service/harbor-pg/leader?raw 2>/dev/null; }
redis_master()  { for i in 0 1 2; do [ "$(kubectl -n $NS exec redis-$i -c valkey -- valkey-cli role 2>/dev/null | head -1)" = master ] && { echo redis-$i; return; }; done; }
consul_leader() { for i in 0 1 2; do l=$(kubectl -n $NS exec consul-$i -- consul operator raft list-peers 2>/dev/null | awk '$4=="leader"{print $1}'); [ -n "$l" ] && { echo "$l"; return; }; done; }
node_of()       { kubectl -n $NS get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
lb_announcer() {  # the lb node whose eth0 carries the Keepalived VIP
  for n in $(kubectl get nodes -l harbor-ha/role=lb -o name | sed 's|node/||'); do
    docker exec "$n" ip -4 addr show eth0 2>/dev/null | grep -q " 172.20.0.100/" && { echo "$n"; return; }
  done
}
node_ready() { [ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }
wait_for() { local what=$1 to=$2; shift 2; local t=$SECONDS; while ! "$@" >/dev/null 2>&1; do [ $((SECONDS-t)) -gt "$to" ] && { echo "   !! timeout waiting for: $what"; return 1; }; sleep 2; done; }

# ---------- victim and role-specific checks
case "$ROLE" in
  lb)     BEFORE=$(lb_announcer);  VICTIM=$BEFORE ;;
  pg)     BEFORE=$(pg_leader);     VICTIM=$(node_of "$BEFORE") ;;
  redis)  BEFORE=$(redis_master);  VICTIM=$(node_of "$BEFORE") ;;
  consul) BEFORE=$(consul_leader); VICTIM=$(node_of "$BEFORE") ;;
  *) echo "unknown role $ROLE"; exit 2 ;;
esac
[ -n "$VICTIM" ] && [ -n "$BEFORE" ] || { echo "!! cannot determine the victim for $ROLE (leader='$BEFORE' node='$VICTIM')"; exit 1; }
SURV_PG=$([ "$BEFORE" = pg-0 ] && echo pg-1 || echo pg-0)
SURV_REDIS=$([ "$BEFORE" = redis-0 ] && echo redis-1 || echo redis-0)
SURV_CONSUL=$([ "$BEFORE" = consul-0 ] && echo consul-1 || echo consul-0)

failover_done() {
  case "$ROLE" in
    lb)     [ "$(kubectl get endpoints harbor-lb -n $NS -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w)" = 1 ] ;;
    pg)     n=$(pg_leader_from "$SURV_PG"); [ -n "$n" ] && [ "$n" != "$BEFORE" ] ;;
    redis)  n=$(kubectl -n $NS exec "$SURV_REDIS" -c sentinel -- valkey-cli -p 26379 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1 | cut -d. -f1); [ -n "$n" ] && [ "$n" != "$BEFORE" ] ;;
    consul) n=$(kubectl -n $NS exec "$SURV_CONSUL" -- consul operator raft list-peers 2>/dev/null | awk '$4=="leader"{print $1}'); [ -n "$n" ] && [ "$n" != "$BEFORE" ] ;;
  esac
}
healthy() {  # the role is fully back
  case "$ROLE" in
    lb)     [ "$(kubectl -n $NS get ds infra-lb --no-headers | awk '{print $4}')" = "2" ] && [ "$(kubectl -n $NS get deploy harbor-lb --no-headers | awk '{print $2}')" = "2/2" ] ;;
    pg)     kubectl -n $NS exec "$SURV_PG" -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null | python3 -c "import sys,json; m=json.load(sys.stdin); sys.exit(0 if len(m)==2 and sorted(x['Role'] for x in m)==['Leader','Replica'] and all(x['State'] in ('running','streaming') for x in m) else 1)" ;;
    redis)  [ "$(for i in 0 1 2; do kubectl -n $NS exec redis-$i -c valkey -- valkey-cli role 2>/dev/null | head -1; done | sort | paste -sd' ')" = "master slave slave" ] && kubectl -n $NS exec "$SURV_REDIS" -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster 2>/dev/null | grep -q "^OK 3" ;;
    consul) [ "$(kubectl -n $NS exec "$SURV_CONSUL" -- consul operator raft list-peers 2>/dev/null | awk 'NR>1' | wc -l)" = 3 ] ;;
  esac
}

echo "== H4.7 role failure: $ROLE   victim node: $VICTIM   (current $ROLE leader/holder: $BEFORE)"
echo "   pods on the victim: $(kubectl get pods -A -o wide --no-headers | awk -v n="$VICTIM" '$8==n||$7==n{print $2}' | grep -vE 'kindnet|kube-proxy' | paste -sd' ')"
healthy || { echo "!! the role is not healthy before the test"; exit 1; }
kubectl get deploy harbor-core harbor-registry --no-headers | awk '{print "   "$1,$2}'
echo "   load: $(cut -d' ' -f1-3 /proc/loadavg)"

# ---------- setup: probe table, counter, writer pods
PGPW=$(sec pg-credentials harbor); RPW=$(sec redis-credentials password)
kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PGPW@harbor-lb.$NS:5432/registry" -Atc "drop table if exists h47_probe; create table h47_probe(id bigserial primary key, ts timestamptz default now())" >/dev/null 2>&1
kubectl -n $NS exec redis-0 -c valkey -- valkey-cli -h harbor-lb.$NS del h47:counter >/dev/null 2>&1
PGW='while true; do o=$(PGCONNECT_TIMEOUT=3 psql -h harbor-lb.harbor-deps -U harbor -d registry -Atc "insert into h47_probe default values returning id" 2>&1); echo "rc=$? $(echo $o | cut -c1-70)"; sleep 0.2; done'
RDW='while true; do o=$(timeout 4 valkey-cli -h harbor-lb.harbor-deps --no-auth-warning incr h47:counter 2>&1); echo "rc=$? $(echo $o | cut -c1-70)"; sleep 0.2; done'
kubectl delete pod h47-pgw h47-redisw --ignore-not-found --wait=true >/dev/null 2>&1
kubectl run h47-pgw --image=$PGI --restart=Never --overrides="$OV" --env=PGPASSWORD="$PGPW" --command -- sh -c "$PGW" >/dev/null
kubectl run h47-redisw --image=$VKI --restart=Never --overrides="$OV" --env=REDISCLI_AUTH="$RPW" --command -- sh -c "$RDW" >/dev/null
kubectl wait --for=condition=ready pod/h47-pgw pod/h47-redisw --timeout=120s >/dev/null 2>&1

restart_snapshot() { kubectl get pods -A -o custom-columns=P:.metadata.namespace,N:.metadata.name,R:.status.containerStatuses[*].restartCount --no-headers 2>/dev/null | awk '{n=0; for(i=3;i<=NF;i++) if ($i ~ /^[0-9]+$/) n+=$i; print $1"/"$2, n}' | sort; }
restart_snapshot > restarts.before
MANIFEST=$(curl -sk -u "$AUTH" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://$HOST/v2/python/hello/manifests/1.0")
BLOB=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(max(d['layers'],key=lambda l:l['size'])['digest'])")

: > manifest.log; : > blob.log; : > pull.log; : > push.log; : > events.log
STOP=$W/stop; rm -f "$STOP"
cleanup() {
  touch "$STOP"; wait 2>/dev/null
  node_ready "$VICTIM" || { echo "   (cleanup) starting $VICTIM"; docker start "$VICTIM" >/dev/null 2>&1; }
  kubectl delete pod h47-pgw h47-redisw --ignore-not-found --wait=false >/dev/null 2>&1
  curl -sk -o /dev/null -u "$AUTH" -X DELETE "$API/projects/python/repositories/h47"
  # the probe table and the counter created by the test (through harbor-lb, so it works after any failover)
  kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PGPW@harbor-lb.$NS:5432/registry" -Atc "drop table if exists h47_probe" >/dev/null 2>&1
  kubectl -n $NS exec redis-0 -c valkey -- valkey-cli -h harbor-lb.$NS del h47:counter >/dev/null 2>&1
  for i in $(seq 1 400); do docker rmi "$HOST/python/h47:$i" >/dev/null 2>&1 || break; done; docker rmi "$HOST/python/h47base:1" >/dev/null 2>&1
}
trap cleanup EXIT
prober() { local name=$1 url=$2 iv=$3
  while [ ! -e "$STOP" ]; do
    r=$(curl -sk -u "$AUTH" -o /dev/null -w "%{http_code} %{time_total}" -m 30 "$url" 2>/dev/null); rc=$?
    echo "$(now_ms) ${r:-000 0} rc=$rc" >> "$name.log"; sleep "$iv"
  done; }
puller() { while [ ! -e "$STOP" ]; do docker rmi "$IMG" >/dev/null 2>&1; s=$(now_ms); timeout 120 docker pull "$IMG" >/dev/null 2>&1; echo "$s $(now_ms) rc=$?" >> pull.log; done; }
# the pusher tags from its own local tag: the pull loop `docker rmi`s python/hello:1.0 all the time
docker tag "$IMG" "$HOST/python/h47base:1" 2>/dev/null
pusher() { i=0; while [ ! -e "$STOP" ]; do i=$((i+1)); s=$(now_ms)
    if docker tag "$HOST/python/h47base:1" "$HOST/python/h47:$i" 2>/dev/null; then timeout 120 docker push "$HOST/python/h47:$i" >/dev/null 2>&1; rc=$?; else rc=99; fi
    echo "$s $(now_ms) rc=$rc n=$i" >> push.log; sleep 3; done; }
prober manifest "https://$HOST/v2/python/hello/manifests/1.0" 0.1 &
prober blob "https://$HOST/v2/python/hello/blobs/$BLOB" 0.4 &
puller & pusher &
sleep 12; ev baseline-end

# ---------- the failure
echo "== KILL $VICTIM ($ROLE)"
docker kill "$VICTIM" >/dev/null; ev node-down
T=$SECONDS; wait_for "node NotReady" 180 bash -c "! kubectl get node $VICTIM -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"; ev node-notready; echo "   NotReady after $((SECONDS-T)) s"
T=$SECONDS; wait_for "role failover detected ($ROLE)" 240 failover_done; ev failover-done; echo "   failover detected $((SECONDS-T)) s after NotReady"
echo "   now: $(case $ROLE in pg) pg_leader_from $SURV_PG;; redis) kubectl -n $NS exec $SURV_REDIS -c sentinel -- valkey-cli -p 26379 sentinel get-master-addr-by-name mymaster | head -1 | cut -d. -f1;; consul) consul_leader;; lb) lb_announcer;; esac)"
sleep "$HOLD"; ev degraded-steady

echo "== START $VICTIM"
docker start "$VICTIM" >/dev/null; ev node-up
T=$SECONDS; wait_for "node Ready" 300 node_ready "$VICTIM"; ev node-ready; echo "   Ready after $((SECONDS-T)) s"
T=$SECONDS; wait_for "role healthy again" 420 healthy; ev recovered; echo "   role fully healthy $((SECONDS-T)) s after the node was Ready"
sleep 25; ev settled
touch "$STOP"; wait

# ---------- integrity of acknowledged writes
echo "== integrity of acknowledged writes"
kubectl logs --timestamps h47-pgw > pgw.log 2>/dev/null; kubectl logs --timestamps h47-redisw > redisw.log 2>/dev/null
kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PGPW@harbor-lb.$NS:5432/registry" -Atc "select id from h47_probe order by id" > pg_ids.txt 2>pg_ids.err
RFINAL=$(kubectl -n $NS exec redis-0 -c valkey -- valkey-cli -h harbor-lb.$NS get h47:counter 2>/dev/null)
python3 "$HERE/h47_analyze.py" "$W" "$RFINAL"
restart_snapshot > restarts.after
echo "   container restarts during the test (pod: before -> after):"
join -o 0,1.2,2.2 restarts.before restarts.after 2>/dev/null | awk '$3>$2{printf "     %s: %s -> %s\n", $1,$2,$3; f=1} END{if(!f) print "     none"}'
echo "   final state: $(kubectl -n $NS exec pg-0 -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null | python3 -c "import sys,json; print([(m['Member'],m['Role'],m['State']) for m in json.load(sys.stdin)])" 2>/dev/null)"
echo "   harbor: $(kubectl get deploy --no-headers | grep harbor- | awk '{print $1"="$2}' | paste -sd' ')   logs in $W"
