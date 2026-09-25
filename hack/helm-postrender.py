#!/usr/bin/env python3
"""Helm post-renderer for the Harbor chart (used by hack/install-harbor-ha.sh).

Chart 1.18.3 has no values for PodDisruptionBudgets and for the core/jobservice probes, so this also adds them (see below).

Adds a `preStop` sleep to the client-facing Harbor Deployments (nginx, core, registry, portal), and an
`$upstream_addr` column to the nginx access log.

Why: on a rolling update Kubernetes sends SIGTERM to the old pod at the same time as it removes the
pod from the Service endpoints. kube-proxy and ingress-nginx need a moment to stop routing to it, so
for a few seconds requests reach a pod that is already shutting down: core got `connection refused`
from the terminating registry and answered 502 to the client (H4.3). The chart has
terminationGracePeriodSeconds: 120 but no preStop hook and no value to set one.

The sleep keeps the old pod serving until the routing has caught up. Requires PyYAML on the host.
env: PRESTOP_SECONDS (default 15)
"""
import os
import re
import sys

import yaml

SECONDS = os.environ.get("PRESTOP_SECONDS", "15")
TARGETS = {"harbor-nginx", "harbor-core", "harbor-registry", "harbor-portal"}

# chart 1.18.3 trivy-sts.yaml has a TAB after `apiVersion: v1` (Go's YAML parser accepts it, PyYAML does not): strip trailing blanks
docs = [d for d in yaml.safe_load_all(re.sub(r"[ \t]+$", "", sys.stdin.read(), flags=re.M)) if d]

# PodDisruptionBudget minAvailable 1 for every replicated component (1.19.2 had podDisruptionBudget values, 1.18.3 has none)
PDB_COMPONENTS = {"harbor-nginx": "nginx", "harbor-core": "core", "harbor-portal": "portal",
                  "harbor-jobservice": "jobservice", "harbor-registry": "registry"}

# core and jobservice liveness must survive a Redis failover (H4.7): their probes hang while Redis is unreachable, and the
# chart default (core: failureThreshold 2, timeout 1 s) made kubelet kill both cores. Liveness now tolerates ~60 s; readiness
# stays fast so a core without Redis leaves the load balancing instead of being restarted. Chart 1.18.3 hardcodes the
# probes (core: failureThreshold 2, period 10; jobservice: initialDelaySeconds 300), so the fields are added here.
LIVENESS = {"harbor-core": {"timeoutSeconds": 5, "failureThreshold": 6},
            "harbor-jobservice": {"timeoutSeconds": 5, "failureThreshold": 6}}
extra = []
for d in docs:
    if d.get("kind") == "Deployment" and d["metadata"]["name"] in TARGETS:
        for c in d["spec"]["template"]["spec"]["containers"]:
            c.setdefault("lifecycle", {})["preStop"] = {
                "exec": {"command": ["sh", "-c", f"sleep {SECONDS}"]}
            }
    if d.get("kind") == "Deployment" and d["metadata"]["name"] in LIVENESS:
        for c in d["spec"]["template"]["spec"]["containers"]:
            if "livenessProbe" in c:
                c["livenessProbe"].update(LIVENESS[d["metadata"]["name"]])
    if d.get("kind") == "Deployment" and d["metadata"]["name"] in PDB_COMPONENTS:
        extra.append({"apiVersion": "policy/v1", "kind": "PodDisruptionBudget",
                      "metadata": {"name": d["metadata"]["name"], "namespace": d["metadata"].get("namespace", "default"),
                                   "labels": d["metadata"].get("labels", {})},
                      "spec": {"minAvailable": 1, "selector": {"matchLabels": {"app": "harbor", "component": PDB_COMPONENTS[d["metadata"]["name"]]}}}})
    # nginx proxies to the Services core/portal, so $upstream_addr is a ClusterIP, not a pod: the column is useless for
    # per-replica counts (V12 counts per nginx pod and in the registry log) but names the upstream Service in a 5xx line.
    if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "harbor-nginx" and "nginx.conf" in d.get("data", {}):
        d["data"]["nginx.conf"] = d["data"]["nginx.conf"].replace("$request_time $upstream_response_time $pipe';", "$request_time $upstream_response_time $pipe $upstream_addr';")
yaml.safe_dump_all(docs + extra, sys.stdout, sort_keys=False, default_flow_style=False)
