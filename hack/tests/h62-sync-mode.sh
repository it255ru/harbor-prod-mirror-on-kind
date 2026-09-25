#!/usr/bin/env bash
# H6.2 (backlog): what Patroni's synchronous_mode changes. One run = one mode (off | on | strict):
#   * a writer pod (app node, through harbor-lb:5432) inserts a row every ~0.3 s and logs start/end times and the result;
#   * phase 1: the REPLICA pod is deleted; phase 2: the LEADER pod is deleted (each waits until Patroni is healthy again);
#   * the analysis prints failed writes, the longest time without an acknowledged write, and acknowledged rows lost.
# The cluster config is restored (mode off) at the end; the probe table is dropped.
# usage: hack/tests/h62-sync-mode.sh <off|on|strict>       env: WORKDIR
set -uo pipefail
MODE=${1:?off|on|strict}
NS=harbor-deps; W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"
pc() { kubectl -n $NS exec pg-0 -- patronictl -c /etc/patroni/patroni.yml "$@" 2>/dev/null || kubectl -n $NS exec pg-1 -- patronictl -c /etc/patroni/patroni.yml "$@"; }
leader() { kubectl -n $NS exec consul-0 -- consul kv get service/harbor-pg/leader 2>/dev/null | tr -d '\r'; }
healthy() {  # one leader running and one streaming replica
  local j; j=$(pc list -f json 2>/dev/null) || return 1
  echo "$j" | python3 -c 'import sys,json; m=json.load(sys.stdin); sys.exit(0 if sum(x["Role"] in ("Leader","Sync Standby") or x["Role"]=="Replica" for x in m)==2 and any(x["Role"]=="Leader" and x["State"]=="running" for x in m) and all(x["State"] in ("running","streaming") for x in m) else 1)'
}
wait_healthy() { local n=0; until healthy; do sleep 3; n=$((n+1)); [ $n -gt 60 ] && { echo "not healthy after 180 s"; return 1; }; done; }
# clock: kernel uptime in seconds (busybox date in the writer has no milliseconds; containers share the host kernel clock)
up() { cut -d" " -f1 /proc/uptime; }
ev() { echo "$(up) $1" >> "$W/events.log"; echo "   $(date +%T) $1"; }
recreated() { kubectl -n $NS wait --for=delete "pod/$1" --timeout=90s >/dev/null 2>&1; kubectl -n $NS wait --for=condition=ready "pod/$1" --timeout=180s >/dev/null 2>&1; }
: > "$W/events.log"

cleanup() {
  kubectl -n $NS delete pod h62-writer --now --ignore-not-found >/dev/null 2>&1
  pc edit-config --force -s synchronous_mode= -s synchronous_mode_strict= >/dev/null 2>&1
  wait_healthy >/dev/null 2>&1
  L=$(leader); PW=$(kubectl -n $NS get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d)
  kubectl -n $NS exec "$L" -- psql "postgresql://harbor:$PW@$L.pg-headless:5432/registry" -Atc "drop table if exists h62_probe" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== mode: $MODE   (start: $(healthy && echo healthy || echo NOT healthy))"
healthy || exit 1
case $MODE in
  on) pc edit-config --force -s synchronous_mode=true >/dev/null;;
  strict) pc edit-config --force -s synchronous_mode=true -s synchronous_mode_strict=true >/dev/null;;
  off) ;;
esac
sleep 15; wait_healthy
echo "-- Patroni after the switch:"; pc list | sed 's/^/   /'
L=$(leader); PW=$(kubectl -n $NS get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d)
echo "   synchronous_standby_names on $L: '$(kubectl -n $NS exec "$L" -- psql "postgresql://harbor:$PW@$L.pg-headless:5432/registry" -Atc 'show synchronous_standby_names')'"
kubectl -n $NS exec "$L" -- psql "postgresql://harbor:$PW@$L.pg-headless:5432/registry" -Atc "drop table if exists h62_probe; create table h62_probe(id bigserial primary key, t timestamptz default now())" >/dev/null

kubectl -n $NS run h62-writer --restart=Never --image=postgres:15.19-alpine3.24@sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81 \
  --env=PGPASSWORD="$PW" --overrides='{"spec":{"nodeSelector":{"harbor-ha/role":"app"},"tolerations":[{"key":"harbor-ha/role","operator":"Equal","value":"app","effect":"NoSchedule"}]}}' \
  --command -- sh -c 'while true; do s=$(cut -d" " -f1 /proc/uptime); out=$(psql "host=harbor-lb port=5432 user=harbor dbname=registry connect_timeout=3 options=-cstatement_timeout=20000" -Atc "insert into h62_probe default values returning id" 2>&1 | head -1 | cut -c1-60); echo "$s $(cut -d" " -f1 /proc/uptime) $out"; sleep 0.3; done' >/dev/null
kubectl -n $NS wait --for=condition=ready pod/h62-writer --timeout=90s >/dev/null
sleep 12; ev baseline-done
REPLICA=$([ "$L" = pg-0 ] && echo pg-1 || echo pg-0)
ev "delete-replica:$REPLICA"; kubectl -n $NS delete pod "$REPLICA" --wait=false >/dev/null
sleep 5; echo "-- Patroni 5 s after deleting the replica:"; pc list | sed 's/^/   /'
recreated "$REPLICA"; wait_healthy; ev replica-healthy; sleep 15
ev "delete-leader:$L"; kubectl -n $NS delete pod "$L" --wait=false >/dev/null
recreated "$L"; wait_healthy; ev leader-healthy; sleep 15; ev end
echo "-- Patroni at the end:"; pc list | sed 's/^/   /'
kubectl -n $NS logs h62-writer --timestamps=false > "$W/writer.log" 2>/dev/null
L2=$(leader); kubectl -n $NS exec "$L2" -- psql "postgresql://harbor:$PW@$L2.pg-headless:5432/registry" -Atc "select id from h62_probe" > "$W/ids.txt"
python3 - "$W" <<'PY'
import sys, re
w = sys.argv[1]
ev = [(float(a), b) for a, b in (l.split(" ", 1) for l in open(w + "/events.log").read().splitlines())]
def phase(t):
    p = "baseline"
    for et, n in ev:
        if t >= et: p = n.split(":")[0]
    return p
rows, acked = [], set()
for l in open(w + "/writer.log").read().splitlines():
    m = re.match(r"([\d.]+) ([\d.]+) (.*)", l)
    if not m: continue
    s, e, out = float(m[1]), float(m[2]), m[3].strip()
    ok = out.isdigit()
    if ok: acked.add(int(out))
    rows.append((s, e, ok, out))
present = {int(x) for x in open(w + "/ids.txt").read().split() if x.strip().isdigit()}
print(f"writes: {len(rows)}, failed {sum(1 for r in rows if not r[2])}, slowest {max(r[1]-r[0] for r in rows):.1f}s")
oks = [r for r in rows if r[2]]
by = {}
for s, e, ok, out in rows:
    k = phase(s); by.setdefault(k, [0, 0, 0.0, 0.0]); by[k][0] += 1; by[k][1] += (not ok); by[k][2] = max(by[k][2], e - s)
gaps = {}
for a, b in zip(oks, oks[1:]):
    k = phase(a[1]); gaps[k] = max(gaps.get(k, 0), b[1] - a[1])
for k, (n, f, slow, _) in by.items():
    print(f"  {k:<16} writes={n:<5} failed={f:<4} slowest={slow:5.1f}s  longest gap between acknowledged writes={gaps.get(k, 0):5.1f}s")
errs = sorted({r[3] for r in rows if not r[2]})[:4]
if errs: print("  error texts:", errs)
lost = sorted(acked - present)
print(f"  acknowledged rows: {len(acked)}, LOST acknowledged: {len(lost)}")
PY
