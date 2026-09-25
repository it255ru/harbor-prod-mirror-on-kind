#!/usr/bin/env bash
# Local cache of the third-party images and Helm charts the stand needs (backlog H5.5): a rebuild must not depend on
# a third-party registry keeping the artifacts (MinIO's images vanished from quay.io between two builds).
#   image-cache.sh save    pull every ref of hack/images.txt that is not cached yet (FORCE=1: all), `docker save` into the cache,
#                          `helm pull` the pinned chart
#   image-cache.sh load    put the cached images into containerd of the nodes that need them (kind load) and docker load
#                          the `host` ones; run after `make cluster`, before `make infra-lb`
#   image-cache.sh check   online check that every ref is still pullable anonymously (before deleting a working stand)
#   image-cache.sh status  what is cached
# Cache directory: $IMAGE_CACHE, default ~/.cache/harbor-ha (outside the repository, about 2 GB). Chart archives in
# $IMAGE_CACHE/charts are preferred by install-harbor-ha.sh when present.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${IMAGE_CACHE:-$HOME/.cache/harbor-ha}"
LIST="${IMAGE_LIST:-$HERE/images.txt}"
CLUSTER="${CLUSTER:-harbor}"
KIND="${KIND:-$HERE/../bin/kind}"; [ -x "$KIND" ] || KIND=kind
CTX="kind-$CLUSTER"
CHARTS=("harbor https://helm.goharbor.io harbor 1.18.3")

entries() { grep -vE '^\s*(#|$)' "$LIST"; }                    # "<ref> <roles>"
slug() { echo "$1" | tr '/:@' '___'; }
# name containerd knows the image by: registry/repo[:tag] or registry/repo@digest (docker.io and library/ implied)
normalize() {
  local ref=$1 first repo tag="" dig=""
  [[ $ref == *@* ]] && { dig=${ref#*@}; ref=${ref%@*}; }
  first=${ref%%/*}
  if [[ $ref != */* ]]; then ref="docker.io/library/$ref"
  elif [[ $first != *.* && $first != *:* && $first != localhost ]]; then ref="docker.io/$ref"; fi
  repo=${ref%:*}; [[ ${ref##*/} == *:* ]] && tag=${ref##*:} || repo=$ref
  if [ -n "$dig" ]; then echo "$repo@$dig"; else echo "$repo:${tag:-latest}"; fi
}
cache_tag() { echo "cache.local/$(slug "$1"):cached"; }

cmd_save() {
  mkdir -p "$CACHE/images" "$CACHE/charts"; local rc=0 ref roles
  while read -r ref roles; do
    [ -s "$CACHE/images/$(slug "$ref").tar" ] && [ -z "${FORCE:-}" ] && { echo "cached  $ref"; continue; }
    if ! docker image inspect "$ref" >/dev/null 2>&1; then
      echo "pull $ref"; docker pull -q "$ref" >/dev/null || { echo "FAILED to pull $ref" >&2; rc=1; continue; }
    fi
    docker tag "$ref" "$(cache_tag "$ref")" && docker save "$(cache_tag "$ref")" -o "$CACHE/images/$(slug "$ref").tar" \
      && echo "saved $(du -h "$CACHE/images/$(slug "$ref").tar" | cut -f1)  $ref" || rc=1
  done < <(entries)
  for c in "${CHARTS[@]}"; do
    set -- $c
    [ -f "$CACHE/charts/$3-$4.tgz" ] && { echo "chart $3-$4 cached"; continue; }
    helm pull "$3" --repo "$2" --version "$4" -d "$CACHE/charts" >/dev/null && echo "saved chart $3-$4" || { echo "FAILED chart $3-$4" >&2; rc=1; }
  done
  echo "cache: $(du -sh "$CACHE" | cut -f1) in $CACHE"; return $rc
}

nodes_for() {                                                    # role -> node names of the running cluster
  case $1 in
    host) return;;
    cp) kubectl --context "$CTX" get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null;;
    *) kubectl --context "$CTX" get nodes -l "harbor-ha/role=$1" -o name 2>/dev/null;;
  esac | sed 's|node/||'
}

cmd_load() {
  local ref roles role n f rc=0 target
  while read -r ref roles; do
    f="$CACHE/images/$(slug "$ref").tar"
    [ -f "$f" ] || { echo "not cached (run: make images-save): $ref" >&2; rc=1; continue; }
    target=$(normalize "$ref")
    for role in ${roles//,/ }; do
      if [ "$role" = host ]; then
        # Docker cannot keep a digest reference for a loaded image, so it is tagged without the digest
        # (never over an existing tag): `make cluster` then falls back to it when the digest form is absent.
        docker image inspect "$ref" >/dev/null 2>&1 && continue
        docker image inspect "${ref%@*}" >/dev/null 2>&1 && continue
        docker load -q -i "$f" >/dev/null && docker tag "$(cache_tag "$ref")" "${ref%@*}" && echo "docker load ${ref%@*}"
        continue
      fi
      for n in $(nodes_for "$role"); do
        if docker exec "$n" ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF "$target"; then continue; fi
        "$KIND" load image-archive "$f" --name "$CLUSTER" --nodes "$n" >/dev/null 2>&1 \
          && docker exec "$n" ctr -n k8s.io images tag "$(cache_tag "$ref")" "$target" >/dev/null 2>&1 \
          && echo "loaded on $n: $target" || { echo "FAILED on $n: $ref" >&2; rc=1; }
      done
    done
  done < <(entries)
  return $rc
}

cmd_check() {
  # ok = the registry answered; MISSING = the registry said "not found / unauthorized" (the MinIO case);
  # UNKNOWN = anything else (timeout, CDN or network error): says nothing about the artifact. Both non-ok are non-zero.
  local ref roles rc=0 r err
  probe() {
    err=$(timeout 90 "$@" 2>&1 >/dev/null); r=$?
    if [ $r != 0 ]; then err=$(timeout 90 "$@" 2>&1 >/dev/null); r=$?; fi   # one retry
    if [ $r = 0 ]; then verdict=ok
    elif echo "$err" | grep -qiE "manifest unknown|no such manifest|not found|denied|unauthorized|requires authentication|401|404"; then verdict=MISSING
    else verdict=UNKNOWN; fi
  }
  while read -r ref roles; do
    probe docker manifest inspect "$ref"
    if [ $verdict = ok ]; then echo "ok       $ref"; else echo "$verdict  $ref ($(echo "$err" | head -1 | cut -c1-80))" >&2; rc=1; fi
  done < <(entries)
  for c in "${CHARTS[@]}"; do
    set -- $c
    probe helm show chart "$3" --repo "$2" --version "$4"
    if [ $verdict = ok ]; then echo "ok       chart $3 $4"; else echo "$verdict  chart $3 $4 ($(echo "$err" | head -1 | cut -c1-80))" >&2; rc=1; fi
  done
  return $rc
}

cmd_status() {
  local ref roles miss=0
  while read -r ref roles; do
    if [ -f "$CACHE/images/$(slug "$ref").tar" ]; then printf '%-8s %s\n' "$(du -h "$CACHE/images/$(slug "$ref").tar" | cut -f1)" "$ref"; else echo "missing  $ref"; miss=1; fi
  done < <(entries)
  ls -1 "$CACHE/charts" 2>/dev/null | sed 's/^/chart    /'; return $miss
}

case "${1:-}" in
  save) cmd_save;; load) cmd_load;; check) cmd_check;; status) cmd_status;;
  *) sed -n '2,13p' "$0"; exit 2;;
esac
