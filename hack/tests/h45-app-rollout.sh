#!/usr/bin/env bash
# H4.5 (backlog): the demo app is rolled out to a NEW image tag pushed to Harbor; the pods pull it from
# Harbor, and the responses (`Hello, Kube! (from <pod>)`) show the load spread over the replicas.
#
# usage: hack/tests/h45-app-rollout.sh
# env:   DEGRADE=1  force-delete one registry pod and one core pod right before the rollout, so the
#                   kubelet pulls while Harbor is running on a single replica of each (default 0)
#        APP_URL (default http://<control-plane IP>:30500, hello-service NodePort), HARBOR_HOST, HARBOR_AUTH, WORKDIR
#
# What it does
#   1. counts which pods answer before the rollout;
#   2. builds python/hello:h45-<epoch> (hello:1.0 + one tiny layer), pushes it to Harbor;
#   3. `kubectl set image` on hello-deployment, with a prober hitting hello-service every ~0.1 s
#      (records pod name and HTTP status), waits for the rollout;
#   4. checks the new pods run the pushed digest, that kubelet pulled from Harbor (events), and counts
#      which pods answer after the rollout;
#   5. restores hello:1.0 and removes the test artifact BY DIGEST (never by tag: a shared tag deletes
#      the other tags of the same artifact).
set -uo pipefail
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
APP_URL=${APP_URL:-http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CLUSTER:-harbor}-control-plane):30500}; DEGRADE=${DEGRADE:-0}
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
TAG=h45-$(date +%s); IMG=$HOST/python/hello:$TAG; BASE=$HOST/python/hello:1.0
now_ms() { date +%s%3N; }
dist() {  # n -> which pods answer
  for _ in $(seq 1 "$1"); do curl -s -m 3 "$APP_URL/" | sed 's/.*(from \(.*\))/\1/'; echo; done | grep -v '^$' | sort | uniq -c | awk '{print "   "$1"x "$2}'
}
DIGEST=""
cleanup() {
  kubectl set image deploy/hello-deployment hello=$BASE >/dev/null 2>&1
  kubectl rollout status deploy/hello-deployment --timeout=180s >/dev/null 2>&1
  if [ -n "$DIGEST" ]; then
    echo "== cleanup: back on $BASE; delete test artifact by digest: $(curl -sk -o /dev/null -w '%{http_code}' -u "$AUTH" -X DELETE "https://$HOST/api/v2.0/projects/python/repositories/hello/artifacts/$DIGEST")"
  fi
  docker rmi "$IMG" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== precondition"
kubectl get deploy hello-deployment --no-headers | awk '{print "   "$1,$2}'
kubectl get deploy hello-deployment -o jsonpath='   image: {.spec.template.spec.containers[0].image}  pullPolicy: {.spec.template.spec.containers[0].imagePullPolicy}{"\n"}'
echo "before the rollout (40 requests):"; dist 40

echo "== build and push $IMG"
printf 'FROM %s\nRUN echo %s > /version\n' "$BASE" "$TAG" > Dockerfile
docker build -q -t "$IMG" . >/dev/null || exit 1
docker push "$IMG" 2>&1 | grep -E "digest:|denied|error" | tee push.log
DIGEST=$(grep -oE "sha256:[0-9a-f]{64}" push.log | head -1)
[ -n "$DIGEST" ] || { echo "!! push failed"; exit 1; }

if [ "$DEGRADE" = 1 ]; then
  echo "== DEGRADE: force-delete one registry pod and one core pod"
  kubectl delete "$(kubectl get pods -l component=registry -o name | head -1)" --grace-period=0 --force 2>&1 | tail -1
  kubectl delete "$(kubectl get pods -l component=core -o name | head -1)" --grace-period=0 --force 2>&1 | tail -1
  echo "   harbor pods now: $(kubectl get pods -l app=harbor --no-headers 2>/dev/null | grep -E 'core|registry' | awk '{print $1":"$2":"$3}' | paste -sd' ')"
fi

: > probe.log; : > events.log; STOP=$W/stop; rm -f "$STOP"
( while [ ! -e "$STOP" ]; do
    r=$(curl -s -m 3 -w " %{http_code}" "$APP_URL/" 2>/dev/null); rc=$?
    echo "$(now_ms) rc=$rc ${r:-none}" >> probe.log; sleep 0.1
  done ) &
sleep 5
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== rollout: kubectl set image -> $TAG"; echo "$(now_ms) rollout-start" >> events.log
kubectl set image deploy/hello-deployment hello=$IMG >/dev/null
kubectl rollout status deploy/hello-deployment --timeout=300s | tail -1
echo "$(now_ms) rollout-done" >> events.log
sleep 5; touch "$STOP"; wait

echo "== new pods"
kubectl get pods -l app=hello -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IMAGEID:.status.containerStatuses[0].imageID --no-headers | sed 's/core.harbor.domain\/python\/hello@//' | awk '{print "   "$1,$2,substr($3,1,26)}'
echo "   pushed digest: ${DIGEST:0:26}"
echo "== kubelet events (pull from Harbor)"
kubectl get events --sort-by=.lastTimestamp -o custom-columns=T:.lastTimestamp,OBJ:.involvedObject.name,R:.reason,M:.message --no-headers 2>/dev/null \
  | grep -E "hello-deployment" | grep -E "$TAG" | grep -E "Pulling|Pulled|Failed|BackOff" | cut -c1-230 | sed 's/^/   /'
echo "== probe analysis"
python3 - "$W" <<'EOF'
import sys, re
from collections import Counter
rows = []
for l in open(sys.argv[1] + "/probe.log"):
    m = re.match(r"(\d+) rc=(\d+) (?:Hello, Kube! \(from (\S+)\) )?(\d+)?", l.strip())
    ms, rc, pod, code = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
    rows.append((ms, rc, pod, code))
ev = [(int(l.split()[0]), l.split()[1]) for l in open(sys.argv[1] + "/events.log")]
start = next(t for t, n in ev if n == "rollout-start"); done = next(t for t, n in ev if n == "rollout-done")
def ph(ms): return "before" if ms < start else ("rollout" if ms <= done else "after")
bad = [r for r in rows if r[1] != 0 or r[3] != "200"]
print(f"   {len(rows)} requests, {len(bad)} failed; rollout took {(done - start) / 1000:.1f}s")
for p in ("before", "rollout", "after"):
    sel = [r for r in rows if ph(r[0]) == p]
    c = Counter(r[2] for r in sel if r[2])
    print(f"   {p:<8} requests={len(sel):<4} errors={sum(1 for r in sel if r in bad):<3} pods answering={len(c)}  {dict(c)}")
for r in bad[:6]:
    print(f"   error at {(r[0] - start) / 1000:+.1f}s rc={r[1]} code={r[3]}")
EOF
echo "== after the rollout (40 requests):"; dist 40
echo "logs in $W"
