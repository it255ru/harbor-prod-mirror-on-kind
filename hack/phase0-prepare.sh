#!/usr/bin/env bash
# Phase 0 — подготовка окружения (без изменения кластера).
# Повторяет baseline-проверки из backlog.md: B0.1–B0.4.
#
# Usage:
#   ./hack/phase0-prepare.sh
#   ./hack/phase0-prepare.sh --create-branch          # B0.4: ветка chore/k8s-1.34-stack
#   ./hack/phase0-prepare.sh --create-branch --init-git  # git init + ветка (если нет .git)
#
# Exit codes:
#   0 — Phase 0 OK (блокеров нет; ветка создана или уже есть)
#   1 — есть блокеры для Phase 1 (kubectl / git / tools)
#   2 — ошибка запуска скрипта

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BRANCH="${PHASE0_BRANCH:-chore/k8s-1.34-stack}"
LOG_DIR="${ROOT}/hack"
LOG_FILE="${LOG_DIR}/phase0-baseline.log"
CREATE_BRANCH=0
INIT_GIT=0

for arg in "$@"; do
  case "$arg" in
    --create-branch) CREATE_BRANCH=1 ;;
    --init-git) INIT_GIT=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

BLOCKERS=()
NOTES=()
ROWS=() # markdown table rows: | check | result |

add_row() {
  ROWS+=("| $1 | $2 |")
}

ok()   { printf '  [OK]  %s\n' "$*"; }
warn() { printf '  [!!]  %s\n' "$*"; }
info() { printf '  [--]  %s\n' "$*"; }

# --- B0.1 / B0.2: tools ---
echo "=== B0.1 / B0.2: host tools & Makefile defaults ==="

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    CGROUP="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo '?')"
    ok "Docker ${DOCKER_VER} (cgroup v${CGROUP})"
    add_row "Docker" "OK \`${DOCKER_VER}\`, cgroup v${CGROUP}"
  else
    warn "Docker installed but daemon not reachable"
    add_row "Docker" "**FAIL** — daemon unreachable"
    BLOCKERS+=("Docker daemon")
  fi
else
  warn "Docker not found"
  add_row "Docker" "**MISSING**"
  BLOCKERS+=("Docker")
fi

if command -v helm >/dev/null 2>&1; then
  HELM_VER="$(helm version --short 2>/dev/null | head -1)"
  # require Helm 3.8+
  HELM_MAJOR_MINOR="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//' | cut -d. -f1,2)"
  HELM_MAJOR="${HELM_MAJOR_MINOR%%.*}"
  HELM_MINOR="${HELM_MAJOR_MINOR##*.}"
  if [[ "${HELM_MAJOR}" -gt 3 ]] || { [[ "${HELM_MAJOR}" -eq 3 ]] && [[ "${HELM_MINOR}" -ge 8 ]]; }; then
    ok "Helm ${HELM_VER} (>= 3.8)"
    add_row "Helm" "OK \`${HELM_VER}\` (≥ 3.8)"
  else
    warn "Helm ${HELM_VER} is older than 3.8"
    add_row "Helm" "**TOO OLD** \`${HELM_VER}\` (need ≥ 3.8)"
    BLOCKERS+=("Helm >= 3.8")
  fi
else
  warn "helm not found"
  add_row "Helm" "**MISSING**"
  BLOCKERS+=("Helm")
fi

if command -v go >/dev/null 2>&1; then
  GO_VER="$(go version 2>/dev/null)"
  ok "${GO_VER}"
  add_row "Go" "OK \`${GO_VER#go version }\`"
else
  warn "go not found (needed for: go install sigs.k8s.io/kind@…)"
  add_row "Go" "**MISSING**"
  BLOCKERS+=("Go")
fi

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VER="$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion:/ {print $2; exit}')"
  ok "kubectl ${KUBECTL_VER:-unknown}"
  add_row "kubectl" "OK \`${KUBECTL_VER:-unknown}\`"
else
  warn "kubectl not found — required before Phase 1"
  add_row "kubectl" "**MISSING** — нужен до Phase 1"
  BLOCKERS+=("kubectl")
fi

# Makefile pins (current, not target)
if [[ -f Makefile ]]; then
  LB_IP="$(awk -F' ?= ' '/^LB_IP /{print $2; exit}' Makefile)"
  KIND_VER="$(awk -F' ?= ' '/^KIND_VERSION /{print $2; exit}' Makefile)"
  KIND_IMAGE="$(awk -F' ?= ' '/^KIND_IMAGE /{print $2; exit}' Makefile)"
  CLUSTER="$(awk -F' ?= ' '/^CLUSTER /{print $2; exit}' Makefile)"
  HARBOR_HOST="$(awk -F' ?= ' '/^HARBOR_HOST /{print $2; exit}' Makefile)"
  ok "Makefile: CLUSTER=${CLUSTER} KIND_VERSION=${KIND_VER} KIND_IMAGE=${KIND_IMAGE}"
  ok "Makefile: LB_IP=${LB_IP} HARBOR_HOST=${HARBOR_HOST}"
  add_row "Makefile \`LB_IP\`" "\`${LB_IP}\` (подтвердить subnet после \`make cluster\`)"
  add_row "Makefile Kind (current)" "\`${KIND_VER}\` / \`${KIND_IMAGE}\`"
else
  warn "Makefile not found in ${ROOT}"
  BLOCKERS+=("Makefile")
fi

# local kind binary
if [[ -x ./bin/kind ]]; then
  LOCAL_KIND_VER="$(./bin/kind version 2>/dev/null || echo unknown)"
  info "./bin/kind present: ${LOCAL_KIND_VER}"
  add_row "\`./bin/kind\`" "present (\`${LOCAL_KIND_VER}\`)"
  NOTES+=("After KIND_VERSION bump, delete ./bin/kind so Make reinstalls")
else
  info "./bin/kind absent (will be installed by make cluster)"
  add_row "\`./bin/kind\`" "отсутствует (установится при \`make cluster\`)"
fi

# --- B0.1: kind docker network ---
echo
echo "=== B0.1: Docker network 'kind' ==="

if docker network inspect kind >/dev/null 2>&1; then
  KIND_NET="$(docker network inspect -f '{{range .IPAM.Config}}subnet={{.Subnet}} gateway={{.Gateway}} {{end}}' kind 2>/dev/null)"
  ok "kind network: ${KIND_NET}"
  add_row "Docker network \`kind\`" "OK \`${KIND_NET}\`"
  if [[ -n "${LB_IP:-}" ]]; then
    # crude check: LB_IP prefix vs subnet (first two octets)
    LB_PREFIX="$(echo "$LB_IP" | cut -d. -f1,2)"
    if echo "$KIND_NET" | grep -q "$LB_PREFIX"; then
      ok "LB_IP ${LB_IP} looks aligned with kind subnet prefix ${LB_PREFIX}"
    else
      warn "LB_IP ${LB_IP} may NOT match kind network — update LB_IP in the Makefile and virtual_ipaddress in hack/ha/infra-lb.yaml together"
      NOTES+=("Revisit LB_IP vs kind subnet before/after make cluster")
    fi
  fi
else
  info "kind network not found (no KinD cluster yet — expected for Phase 0)"
  add_row "Docker network \`kind\`" "**нет** (кластера KinD нет)"
fi

# /etc/hosts
echo
echo "=== B0.1: /etc/hosts ==="
HOST_TARGET="${HARBOR_HOST:-core.harbor.domain}"
if grep -E "[[:space:]]${HOST_TARGET}([[:space:]]|$)" /etc/hosts >/dev/null 2>&1; then
  HOST_LINE="$(grep -E "[[:space:]]${HOST_TARGET}([[:space:]]|$)" /etc/hosts | head -1)"
  ok "hosts entry: ${HOST_LINE}"
  add_row "\`/etc/hosts\`" "есть \`${HOST_TARGET}\`: \`${HOST_LINE}\`"
else
  info "no entry for ${HOST_TARGET} (make add-host later)"
  OTHER_HARBOR="$(grep -i harbor /etc/hosts 2>/dev/null | head -3 || true)"
  if [[ -n "$OTHER_HARBOR" ]]; then
    info "other harbor-related hosts lines:"
    echo "$OTHER_HARBOR" | sed 's/^/         /'
    add_row "\`/etc/hosts\`" "нет \`${HOST_TARGET}\`; другие harbor-записи есть"
  else
    add_row "\`/etc/hosts\`" "нет \`${HOST_TARGET}\`"
  fi
fi

# --- B0.3: existing cluster ---
echo
echo "=== B0.3: existing KinD / Harbor cluster ==="

KIND_BIN=""
if [[ -x ./bin/kind ]]; then
  KIND_BIN=./bin/kind
elif command -v kind >/dev/null 2>&1; then
  KIND_BIN="$(command -v kind)"
fi

CLUSTERS=""
if [[ -n "$KIND_BIN" ]]; then
  CLUSTERS="$("$KIND_BIN" get clusters 2>/dev/null || true)"
fi

CLUSTER_NAME="${CLUSTER:-harbor}"
if echo "$CLUSTERS" | grep -qx "$CLUSTER_NAME"; then
  warn "KinD cluster '${CLUSTER_NAME}' exists — document state or: make cluster-delete (no in-place bump)"
  add_row "Живой кластер Harbor/KinD" "**есть** \`${CLUSTER_NAME}\` — удалить перед bump или задокументировать"
  NOTES+=("Run: make cluster-delete before Phase 1 recreate")
  if command -v kubectl >/dev/null 2>&1; then
    info "kubectl nodes:"
    kubectl --context "kind-${CLUSTER_NAME}" get nodes -o wide 2>/dev/null | sed 's/^/         /' || true
    info "helm list -A:"
    helm --kube-context "kind-${CLUSTER_NAME}" list -A 2>/dev/null | sed 's/^/         /' || true
  fi
elif [[ -n "$CLUSTERS" ]]; then
  info "other kind clusters: $(echo "$CLUSTERS" | tr '\n' ' ')"
  add_row "Живой кластер Harbor/KinD" "нет \`${CLUSTER_NAME}\`; другие: \`$(echo "$CLUSTERS" | tr '\n' ' ')\`"
else
  ok "no KinD cluster '${CLUSTER_NAME}' — cluster-delete not required"
  add_row "Живой кластер Harbor/KinD" "**нет** — \`cluster-delete\` не требуется"
fi

# --- B0.4: git branch ---
echo
echo "=== B0.4: git branch '${BRANCH}' ==="

GIT_OK=0
if [[ -d .git ]] || git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_OK=1
fi

if [[ "$GIT_OK" -eq 0 ]]; then
  if [[ "$INIT_GIT" -eq 1 ]]; then
    info "Initializing git repository…"
    git init
    git checkout -b "$BRANCH"
    ok "git init + branch ${BRANCH}"
    add_row "Git" "initialized; branch \`${BRANCH}\`"
    GIT_OK=1
  else
    warn "not a git repository — cannot create branch"
    add_row "Git" "**нет репозитория** — нужен \`git init\` или \`--init-git\`"
    BLOCKERS+=("git repository (run with --init-git or init manually)")
  fi
fi

if [[ "$GIT_OK" -eq 1 ]]; then
  CURRENT="$(git symbolic-ref --short -q HEAD || echo unknown)"
  if [[ "$CREATE_BRANCH" -eq 1 ]]; then
    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      git checkout "$BRANCH"
      ok "branch ${BRANCH} already exists — checked out"
    elif [[ "$CURRENT" == "$BRANCH" ]]; then
      ok "already on ${BRANCH}"
    else
      git checkout -b "$BRANCH"
      ok "created and checked out ${BRANCH}"
    fi
    CURRENT="$(git symbolic-ref --short -q HEAD || echo unknown)"
    add_row "Git branch" "\`${BRANCH}\` (current: \`${CURRENT}\`)"
  else
    info "on branch: ${CURRENT} (pass --create-branch to create/switch to ${BRANCH})"
    add_row "Git" "OK; current branch \`${CURRENT}\` (use --create-branch for \`${BRANCH}\`)"
    if [[ "$CURRENT" != "$BRANCH" ]]; then
      NOTES+=("B0.4 incomplete until: $0 --create-branch")
    fi
  fi
fi

# --- write log ---
DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DATE_LOCAL="$(date +%Y-%m-%d)"
{
  echo "# Phase 0 baseline log"
  echo
  echo "Generated: ${DATE_UTC} (local date ${DATE_LOCAL})"
  echo "Root: ${ROOT}"
  echo
  echo "| Проверка | Результат |"
  echo "|----------|-----------|"
  for row in "${ROWS[@]}"; do
    echo "$row"
  done
  echo
  if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
    echo "## Blockers before Phase 1"
    echo
    for b in "${BLOCKERS[@]}"; do
      echo "- ${b}"
    done
    echo
  else
    echo "## Blockers before Phase 1"
    echo
    echo "- none"
    echo
  fi
  if [[ ${#NOTES[@]} -gt 0 ]]; then
    echo "## Notes"
    echo
    for n in "${NOTES[@]}"; do
      echo "- ${n}"
    done
    echo
  fi
} >"$LOG_FILE"

echo
echo "=== Summary ==="
echo "Baseline log: ${LOG_FILE}"

if [[ ${#NOTES[@]} -gt 0 ]]; then
  echo "Notes:"
  for n in "${NOTES[@]}"; do
    echo "  - ${n}"
  done
fi

if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  echo "BLOCKERS (Phase 1 not ready):"
  for b in "${BLOCKERS[@]}"; do
    echo "  - ${b}"
  done
  echo
  echo "Phase 0 finished with blockers (exit 1)."
  exit 1
fi

echo "Phase 0 checks passed (exit 0)."
exit 0
