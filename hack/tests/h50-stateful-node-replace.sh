#!/usr/bin/env bash
# H4.10 (backlog): PERMANENT loss and replacement of a node that holds state (pg | redis | consul | s3) or a load-balancer node (lb).
# The volumes are local-path PVs bound to the node: the replacement node has EMPTY volumes.
#
# usage: hack/tests/h50-stateful-node-replace.sh <pg|redis|consul|s3|lb> [node]
#   default victim: pg - the node of the Patroni leader, redis - of the Valkey master, consul - of the raft leader, s3 - the Garage node,
#   lb - the lb node that holds the Keepalived VIP (no volumes; the locally built Keepalived image must be `kind load`ed into the new node)
# env:   CLUSTER (default harbor), KIND (default ./bin/kind), WORKDIR, HEAL_WAIT (seconds to wait for the role to heal by itself, default 240)
#
# What it does:
#   1. writes marker data through the normal path (pg rows / redis keys / consul keys) or notes the object count (s3);
#   2. `docker kill`s the victim (never started again), waits for NotReady, `kubectl delete node`, removes the container;
#   3. builds a replacement node with the same name and role (hack/tests/lib-node.sh), loads the images of the role
#      (the locally built Patroni image needs `kind load`, it is not in the cache), and waits for the role to heal BY ITSELF;
#   4. if it does not, applies the documented repair: pg / redis / consul - delete the PVC and the pod of the member (the volume
#      directory of the replacement node is created by root, the database processes get `Permission denied` on it); s3 - `make s3`
#      re-creates the layout, bucket and key, then the stale Harbor data is cleaned and the demo image is pushed again;
#   5. checks that the marker data is still there and prints how long each step took.
set -uo pipefail
ROLE=${1:?usage: h50-stateful-node-replace.sh <pg|redis|consul|s3|lb> [node]}; NODE=${2:-}
CLUSTER=${CLUSTER:-harbor}; HEAL_WAIT=${HEAL_WAIT:-240}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
KIND="${KIND:-$ROOT/bin/kind}"; [ -x "$KIND" ] || KIND=kind
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
NS=harbor-deps; PG_IMAGE=${PG_IMAGE:-harbor-ha/patroni:4.1.5-pg15.19}; KA_IMAGE=${KA_IMAGE:-harbor-ha/keepalived:2.3.4-alpine3.24}
# shellcheck source=hack/tests/lib-node.sh
. "$HERE/lib-node.sh"
sec() { kubectl -n $NS get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }
step() { echo "$(date +%s) $1" >> steps.log; echo "   [$(date +%T)] $1"; }
wait_for() { local what=$1 to=$2; shift 2; local t=$SECONDS; while ! "$@" >/dev/null 2>&1; do [ $((SECONDS-t)) -gt "$to" ] && { echo "   !! timeout ($to s) waiting for: $what"; return 1; }; sleep 3; done; }
node_of() { kubectl -n $NS get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }

# ---------- role knowledge
pg_json() { kubectl -n $NS exec pg-0 -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null || kubectl -n $NS exec pg-1 -- patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null; }
pg_leader() { pg_json | python3 -c "import sys,json; print(next((m['Member'] for m in json.load(sys.stdin) if m['Role']=='Leader'),''))" 2>/dev/null; }
redis_master() { for i in 0 1 2; do [ "$(kubectl -n $NS exec redis-$i -c valkey -- valkey-cli role 2>/dev/null | head -1)" = master ] && { echo redis-$i; return; }; done; }
consul_leader() { for i in 0 1 2; do l=$(kubectl -n $NS exec consul-$i -- consul operator raft list-peers 2>/dev/null | awk '$4=="leader"{print $1}'); [ -n "$l" ] && { echo "$l"; return; }; done; }
lb_holder() { for n in $(kubectl get nodes -l harbor-ha/role=lb -o name | sed 's|node/||'); do docker exec "$n" ip -4 addr show eth0 2>/dev/null | grep -q " 172.20.0.100/" && { echo "$n"; return; }; done; }
vip_holders() { for n in $(kubectl get nodes -l harbor-ha/role=lb -o name | sed 's|node/||'); do docker exec "$n" ip -4 addr show eth0 2>/dev/null | grep -c " 172.20.0.100/"; done | paste -sd+ | bc; }
vip_status() { curl -sk -o /dev/null -w '%{http_code}' -m 10 https://core.harbor.domain/; }
s3_objects() { kubectl -n $NS exec garage-0 -- /garage bucket info registry-blobs 2>/dev/null | awk '/^Objects:/{print $2}'; }
healthy() {
  case "$ROLE" in
    pg)     pg_json | python3 -c "import sys,json; m=json.load(sys.stdin); sys.exit(0 if len(m)==2 and sorted(('Replica' if x['Role']=='Sync Standby' else x['Role']) for x in m)==['Leader','Replica'] and all(x['State'] in ('running','streaming') for x in m) else 1)" ;;
    redis)  [ "$(for i in 0 1 2; do kubectl -n $NS exec redis-$i -c valkey -- valkey-cli role 2>/dev/null | head -1; done | sort | paste -sd' ')" = "master slave slave" ] && kubectl -n $NS exec redis-1 -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster 2>/dev/null | grep -q "^OK 3" ;;
    consul) [ "$(for i in 0 1 2; do kubectl -n $NS exec consul-$i -- consul operator raft list-peers 2>/dev/null | awk 'NR>1' | wc -l; done | sort -u | paste -sd' ')" = 3 ] && [ -n "$(consul_leader)" ] ;;
    s3)     [ -n "$(s3_objects)" ] && kubectl -n $NS exec garage-0 -- /garage status 2>/dev/null | grep -q dc1 ;;
    lb)     [ "$(kubectl -n $NS get ds infra-lb --no-headers | awk '{print $4}')" = 2 ] && [ "$(kubectl -n $NS get deploy harbor-lb --no-headers | awk '{print $2}')" = 2/2 ] && [ "$(vip_holders)" = 1 ] && [ "$(vip_status)" = 200 ] ;;
  esac
}
diag() { echo "   -- diagnostics:"; kubectl -n $NS get pods -o wide --no-headers | grep -E "^($1)" | awk '{print "     "$1,$2,$3,$4,$7}'; kubectl -n $NS logs "$2" --tail=4 2>&1 | cut -c1-170 | sed 's/^/     | /'; }

# ---------- victim and the pod that lives on it
case "$ROLE" in
  pg)     HOLDER=$(pg_leader);      POD=$HOLDER ;;
  redis)  HOLDER=$(redis_master);   POD=$HOLDER ;;
  consul) HOLDER=$(consul_leader);  POD=$HOLDER ;;
  s3)     HOLDER=garage-0;          POD=garage-0 ;;
  lb)     HOLDER=$(lb_holder);      POD=$(kubectl -n $NS get pods -l app=infra-lb -o custom-columns=N:.metadata.name,NODE:.spec.nodeName --no-headers | awk -v n="$HOLDER" '$2==n{print $1}') ;;
  *) echo "unknown role $ROLE"; exit 2 ;;
esac
[ -n "$NODE" ] || NODE=$(node_of "$POD")
[ -n "$NODE" ] && [ -n "$POD" ] || { echo "!! cannot determine the victim ($ROLE holder='$HOLDER')"; exit 1; }
POD=$(kubectl -n $NS get pods -o custom-columns=N:.metadata.name,NODE:.spec.nodeName --no-headers | awk -v n="$NODE" '$2==n && $1 ~ /^(pg|redis|consul|garage|infra-lb)-/{print $1; exit}')
[ -n "$POD" ] || { echo "!! no state-holding pod on $NODE"; exit 1; }
echo "== H4.10 stateful node replacement: $ROLE   victim node: $NODE   pod on it: $POD (role holder now: $HOLDER)"
healthy || { echo "!! the role is not healthy before the test"; exit 1; }
echo "   load: $(cut -d' ' -f1-3 /proc/loadavg)"

# ---------- marker data through the normal path
case "$ROLE" in
  pg)     PW=$(sec pg-credentials harbor)
          kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PW@harbor-lb.$NS:5432/registry" -Atc "drop table if exists h50_probe; create table h50_probe(id int primary key); insert into h50_probe select generate_series(1,200)" >/dev/null 2>&1
          sleep 3; BEFORE=$(kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PW@harbor-lb.$NS:5432/registry" -Atc "select count(*) from h50_probe" 2>/dev/null); MARK="rows in h50_probe" ;;
  redis)  kubectl -n $NS exec redis-0 -c valkey -- sh -c 'for i in $(seq 50); do valkey-cli -h harbor-lb.harbor-deps set h50:k$i v$i >/dev/null; done' 2>/dev/null
          sleep 3; BEFORE=$(kubectl -n $NS exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps --scan --pattern "h50:*" | wc -l' 2>/dev/null); MARK="keys h50:*" ;;
  consul) for i in $(seq 10); do kubectl -n $NS exec consul-0 -- consul kv put h50/k$i v$i >/dev/null 2>&1; done
          BEFORE=$(kubectl -n $NS exec consul-0 -- consul kv get -recurse h50/ 2>/dev/null | wc -l); MARK="consul keys h50/" ;;
  s3)     BEFORE=$(s3_objects); MARK="objects in registry-blobs" ;;
  lb)     BEFORE=$(vip_status); MARK="HTTP status of https://core.harbor.domain/ through the VIP" ;;
esac
echo "   marker before: $BEFORE $MARK"

# ---------- the failure and the administrator's reaction
save_node "$NODE" || { echo "!! cannot save the settings of $NODE"; exit 1; }
S0=$SECONDS; echo "== KILL $NODE (it will not come back)"; docker kill "$NODE" >/dev/null; step node-down
wait_for "node NotReady" 180 bash -c "! kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"; step node-notready
sleep 30
echo "   state with the node lost:"; case "$ROLE" in pg) pg_json | python3 -c "import sys,json; [print('     ',m['Member'],m['Role'],m['State']) for m in json.load(sys.stdin)]" ;; redis) echo "     master now: $(redis_master)";; consul) echo "     leader now: $(consul_leader)";; s3) echo "     Garage is gone: registry data path down";; lb) echo "     VIP now on: $(lb_holder), https through it: $(vip_status)";; esac
echo "== administrator: delete the node object and the dead container, build the replacement"
kubectl delete node "$NODE" --wait=true >/dev/null 2>&1; docker rm -f "$NODE" >/dev/null 2>&1; step node-deleted
build_node "$NODE" || { echo "!! replacement node failed"; exit 1; }
wait_for "node Ready" 300 bash -c "[ \"\$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"; step node-ready
CLUSTER=$CLUSTER KIND=$KIND "$ROOT/hack/image-cache.sh" load 2>&1 | grep -E "FAILED" | head
[ "$ROLE" = pg ] && { "$KIND" load docker-image "$PG_IMAGE" --name "$CLUSTER" --nodes "$NODE" >/dev/null 2>&1 && echo "   locally built $PG_IMAGE loaded into $NODE"; }
[ "$ROLE" = lb ] && { "$KIND" load docker-image "$KA_IMAGE" --name "$CLUSTER" --nodes "$NODE" >/dev/null 2>&1 && echo "   locally built $KA_IMAGE loaded into $NODE"; }
step images-loaded

# ---------- does the role heal by itself?
echo "== waiting up to $HEAL_WAIT s for the role to heal by itself (the pod restarts on the new node with an EMPTY volume)"
if wait_for "role healthy" "$HEAL_WAIT" healthy; then step healed-by-itself; HEAL=self
else
  diag "$POD" "$POD"
  echo "== not healed: documented repair = delete the PVC and the pod of $POD (a fresh member re-joins from the survivors)"
  case "$ROLE" in
    s3) step repair-s3; ( cd "$ROOT" && make s3 2>&1 | tail -3 ) ;;
    lb) echo "   (no volumes on an lb node: nothing to reset)"; step no-repair-possible ;;
    *)  kubectl -n $NS delete pvc data-$POD --wait=false >/dev/null 2>&1; kubectl -n $NS delete pod $POD --wait=true >/dev/null 2>&1; step repair-pvc-reset ;;
  esac
  wait_for "role healthy after the repair" 420 healthy && { step healed-after-repair; HEAL=repair; } || { step NOT-HEALED; HEAL=none; diag "$POD" "$POD"; }
fi

# ---------- data
echo "== marker data after"
case "$ROLE" in
  pg)     AFTER=$(kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PW@harbor-lb.$NS:5432/registry" -Atc "select count(*) from h50_probe" 2>/dev/null); kubectl -n $NS exec pg-0 -- psql "postgresql://harbor:$PW@harbor-lb.$NS:5432/registry" -Atc "drop table if exists h50_probe" >/dev/null 2>&1 ;;
  redis)  AFTER=$(kubectl -n $NS exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps --scan --pattern "h50:*" | wc -l' 2>/dev/null); kubectl -n $NS exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps --scan --pattern "h50:*" | xargs -r valkey-cli -h harbor-lb.harbor-deps del' >/dev/null 2>&1 ;;
  consul) AFTER=$(kubectl -n $NS exec consul-0 -- consul kv get -recurse h50/ 2>/dev/null | wc -l); kubectl -n $NS exec consul-0 -- consul kv delete -recurse h50/ >/dev/null 2>&1 ;;
  s3)     AFTER=$(s3_objects) ;;
  lb)     AFTER=$(vip_status); echo "   VIP holders: $(vip_holders) (expected 1), on $(lb_holder)" ;;
esac
echo "   $MARK: before ${BEFORE:-?}, after ${AFTER:-?}"
if [ "$ROLE" = s3 ]; then
  echo "== Harbor after the loss of the blob store"
  echo "   pull of python/hello:1.0 -> $(docker rmi core.harbor.domain/python/hello:1.0 >/dev/null 2>&1; timeout 60 docker pull core.harbor.domain/python/hello:1.0 2>&1 | tail -1 | cut -c1-120)"
  echo "   -> the blobs are gone with the disk. Harbor still lists the artifacts and the registry still has its blob-descriptor cache in Redis"
  echo "      (db 2), so a plain re-push would skip the layers ('already exists'): clean both, then push again"
  A=https://core.harbor.domain/api/v2.0
  echo "   delete repository python/hello: $(curl -sk -o /dev/null -w '%{http_code}' -u admin:Harbor12345 -X DELETE $A/projects/python/repositories/hello)"
  echo "   flush the registry cache (redis db 2): $(kubectl -n $NS exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps -n 2 flushdb' 2>&1 | tail -1)"
  ( cd "$ROOT" && make deploy-app 2>&1 | tail -1 | cut -c1-150 )
  echo "   pull of python/hello:1.0 -> $(docker rmi core.harbor.domain/python/hello:1.0 >/dev/null 2>&1; timeout 60 docker pull core.harbor.domain/python/hello:1.0 2>&1 | tail -1 | cut -c1-120)"
fi

echo "== timeline (seconds from the kill)"
T0=$(head -1 steps.log | cut -d' ' -f1); awk -v t0="$T0" '{printf "   +%4ds  %s\n", $1-t0, $2}' steps.log
echo "== result: role $ROLE  healed: $HEAL  marker: ${BEFORE:-?} -> ${AFTER:-?}   logs in $W"
