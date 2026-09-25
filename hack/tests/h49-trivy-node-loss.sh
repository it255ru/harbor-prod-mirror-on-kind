#!/usr/bin/env bash
# H4.9 (backlog): the scanner survives the loss of an app node (Trivy runs as 2 replicas, one per app node).
#
# usage: hack/tests/h49-trivy-node-loss.sh [node]        (default: harbor-worker2)
# env:   HOLD (seconds to keep the node down, default 130: past NotReady at ~50 s), WORKDIR, HARBOR_HOST, HARBOR_AUTH
#
# What it does:
#   1. precondition: harbor-trivy is 2/2, one pod on each app node;
#   2. warm-up: scans python/hello:1.0 until BOTH replicas hold their vulnerability databases (each downloads ~1.3 GB on the first scan
#      it serves), otherwise the first scan on a cold replica would be slow for a reason that has nothing to do with the failure;
#   3. baseline: 3 scans (time to Success);
#   4. `docker kill` the node, then a scan every ~5 s for HOLD seconds (each waits for the final status, at most 180 s);
#   5. `docker start` the node, wait for Ready and for both replicas, 3 more scans.
# A scan = POST .../scan on the artifact, then polling scan_overview until Success / Error / Stopped.
set -uo pipefail
NODE=${1:-harbor-worker2}; HOLD=${HOLD:-130}
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
API=https://$HOST/api/v2.0; ART="$API/projects/python/repositories/hello/artifacts/1.0"
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
now() { date +%s; }
phase=baseline; : > scans.log
scan_once() {  # prints "<status> <seconds>"; appends to scans.log with the current phase
  local t0 st="Timeout" i
  curl -sk -o /dev/null -u "$AUTH" -X POST "$ART/scan"
  for i in $(seq 1 90); do
    st=$(curl -sk -m 10 -u "$AUTH" "$ART?with_scan_overview=true" -H 'X-Accept-Vulnerabilities: application/vnd.security.vulnerability.report; version=1.1' \
         | python3 -c "import sys,json; d=json.load(sys.stdin); o=list((d.get('scan_overview') or {}).values()); print(o[0]['scan_status'] if o else 'none')" 2>/dev/null)
    case "$st" in Success|Error|Stopped) break;; esac; sleep 2; st=${st:-noreply}
  done
  echo "$phase $st $(( $(now) - S0 ))" ; }
one() { S0=$(now); r=$(scan_once); echo "$(now) $r" >> scans.log; echo "   [$(date +%T)] $r"; }
trivy_ready() { [ "$(kubectl get sts harbor-trivy -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 2 ]; }
db_size() { kubectl exec "harbor-trivy-$1" -- du -sm /home/scanner/.cache 2>/dev/null | cut -f1; }
node_ready() { [ "$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; }

echo "== precondition"
trivy_ready || { echo "!! harbor-trivy is not 2/2"; exit 1; }
kubectl get pods -l component=trivy -o wide --no-headers | awk '{print "   "$1,$3,$7}'
[ "$(kubectl get pods -l component=trivy -o wide --no-headers | awk '{print $7}' | sort -u | wc -l)" = 2 ] || { echo "!! trivy pods are not on two different nodes"; exit 1; }
echo "== warm-up (both replicas need their databases)"
for i in $(seq 1 12); do
  a=$(db_size 0); b=$(db_size 1); echo "   caches: trivy-0=${a:-?} MB, trivy-1=${b:-?} MB"
  [ "${a:-0}" -gt 200 ] && [ "${b:-0}" -gt 200 ] && break
  one
done
phase=baseline; echo "== baseline"; for i in 1 2 3; do one; done

echo "== KILL $NODE"; docker kill "$NODE" >/dev/null; phase=outage; T=$(now)
while [ $(( $(now) - T )) -lt "$HOLD" ]; do one; sleep 5; done
echo "== START $NODE"; docker start "$NODE" >/dev/null; phase=recovering
for i in $(seq 1 150); do node_ready && break; sleep 2; done
for i in $(seq 1 90); do trivy_ready && break; sleep 2; done
echo "   node Ready, harbor-trivy $(kubectl get sts harbor-trivy -o jsonpath='{.status.readyReplicas}')/2"
phase=after; echo "== after"; for i in 1 2 3; do one; done

echo "== analysis"
python3 - <<'EOF'
import collections
rows=[l.split() for l in open('scans.log') if l.strip()]
by=collections.OrderedDict()
for t,ph,st,sec in rows: by.setdefault(ph,[]).append((st,int(sec)))
for ph,v in by.items():
    ok=[s for st,s in v if st=='Success']; bad=[(st,s) for st,s in v if st!='Success']
    print(f"  {ph:10s} scans={len(v):3d} success={len(ok):3d} failed={len(bad):3d}" + (f"  time to Success: median {sorted(ok)[len(ok)//2]} s, max {max(ok)} s" if ok else "") + (f"  failures: {bad[:6]}" if bad else ""))
EOF
echo "   final: nodes $(kubectl get nodes --no-headers | grep -vc ' Ready') not Ready; trivy $(kubectl get sts harbor-trivy -o jsonpath='{.status.readyReplicas}')/2; logs in $W"
