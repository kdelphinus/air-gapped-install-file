#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="$(pwd)"
MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
ADMIN_CONF="/etc/kubernetes/admin.conf"
MARKER="/etc/kubernetes/installer/join-window-open"

usage() {
    echo "사용법: sudo ./scripts/join_window.sh <open|close|status>"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[오류] sudo로 실행해야 합니다.${NC}"
        exit 1
    fi
}

verify_control_plane() {
    if [ ! -f "$MANIFEST" ] || [ ! -f "$ADMIN_CONF" ]; then
        echo -e "${RED}[오류] 이 노드에서 초기화된 Control Plane을 찾지 못했습니다.${NC}"
        exit 1
    fi
    if ! grep -Eq '^[[:space:]]*- --anonymous-auth=(true|false)$' "$MANIFEST"; then
        echo -e "${RED}[오류] kube-apiserver anonymous-auth 설정을 찾지 못했습니다.${NC}"
        exit 1
    fi
}

wait_for_api() {
    local desired="$1"
    local attempt
    local server
    local status
    server=$(KUBECONFIG="$ADMIN_CONF" kubectl config view --minify \
        -o jsonpath='{.clusters[0].cluster.server}')

    for attempt in $(seq 1 60); do
        status=$(curl -ks -o /dev/null -w '%{http_code}' \
            "${server}/api/v1/namespaces/kube-public/configmaps/cluster-info" \
            || true)
        if KUBECONFIG="$ADMIN_CONF" kubectl get --raw=/readyz \
            >/dev/null 2>&1; then
            if [ "$desired" = "true" ] && [ "$status" = "200" ]; then
                return 0
            fi
            if [ "$desired" = "false" ] && [ "$status" = "401" ]; then
                return 0
            fi
        fi
        sleep 2
    done
    echo -e "${RED}[오류] anonymous-auth=${desired} 상태가 120초 안에 반영되지 않았습니다.${NC}"
    return 1
}

set_anonymous_auth() {
    local desired="$1"
    sed -Ei \
        "s#^([[:space:]]*- --anonymous-auth=)(true|false)\$#\\1${desired}#" \
        "$MANIFEST"
}

show_status() {
    local current
    current=$(sed -nE \
        's/^[[:space:]]*- --anonymous-auth=(true|false)$/\1/p' \
        "$MANIFEST")
    echo "anonymous-auth=${current}"
    if [ "$current" = "true" ]; then
        echo -e "${YELLOW}가입 창이 열려 있습니다. 가입 완료 후 즉시 close 하십시오.${NC}"
    else
        echo -e "${GREEN}가입 창이 닫혀 있습니다.${NC}"
    fi
}

require_root
verify_control_plane

case "${1:-}" in
    open)
        echo -e "${YELLOW}[경고] kubeadm join을 위해 cluster-info 익명 조회를 일시 허용합니다.${NC}"
        install -d -m 0700 "$(dirname "$MARKER")"
        install -m 0600 /dev/null "$MARKER"
        set_anonymous_auth true
        wait_for_api true
        show_status
        ;;
    close)
        echo -e "${CYAN}가입 창을 닫고 보안 기준을 복원합니다.${NC}"
        set_anonymous_auth false
        wait_for_api false
        rm -f "$MARKER"
        show_status
        bash "${BASE_DIR}/scripts/security_audit.sh"
        ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac
