#!/usr/bin/env bash
# Helpers to save a kind worker's settings and to build a replacement node for it (sourced by h50-stateful-node-replace.sh).
# kind cannot add a node to a running cluster: the replacement is a kindest/node container with the same settings kind uses,
# joined with `kubeadm join` and the JoinConfiguration the dead node had (/kind/kubeadm.conf: role label, taint).
# needs: CLUSTER, and the working directory to write kubeadm.conf into.
CP=${CP:-${CLUSTER:-harbor}-control-plane}

save_node() {      # save_node <node>: call BEFORE the node is killed
  NODE_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$1") || return 1
  docker exec "$1" cat /kind/kubeadm.conf > kubeadm.conf
}

build_node() {     # build_node <node>: the dead container must be removed already; prints the join log on failure
  local node=$1 token newip
  token=$(docker exec "$CP" kubeadm token create --ttl 15m) || return 1
  docker run -d --name "$node" --hostname "$node" --network kind --privileged \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable \
    --tmpfs /tmp --tmpfs /run -v /lib/modules:/lib/modules:ro -v /var --restart on-failure:1 \
    --label io.x-k8s.kind.cluster="${CLUSTER:-harbor}" --label io.x-k8s.kind.role=worker -e KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER \
    "$NODE_IMAGE" >/dev/null || return 1
  local t=$SECONDS; until docker exec "$node" systemctl is-active containerd >/dev/null 2>&1; do [ $((SECONDS-t)) -gt 90 ] && return 1; sleep 2; done
  newip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node")
  sed -e "s|node-ip: .*|node-ip: $newip|" -e "s|token: .*|token: $token|" kubeadm.conf > kubeadm.new.conf
  docker cp kubeadm.new.conf "$node:/kind/kubeadm.conf"
  docker exec "$node" kubeadm join --config /kind/kubeadm.conf --skip-phases=preflight > join.log 2>&1 || { tail -5 join.log; return 1; }
}
