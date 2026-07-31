#!/usr/bin/env bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}[FAIL]${NC} %s\n" "$1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[오류] sudo로 실행해야 합니다.${NC}"
        exit 2
    fi
}

check_ubuntu_host() {
    if [ -r /sys/module/apparmor/parameters/enabled ] &&
       grep -qx 'Y' /sys/module/apparmor/parameters/enabled; then
        pass "AppArmor 활성화"
    else
        fail "AppArmor 비활성화"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        pass "UFW 활성화"
    else
        fail "UFW 비활성화"
    fi

    if grep -Eq '^[[:space:]]*SystemdCgroup[[:space:]]*=[[:space:]]*true' \
        /etc/containerd/config.toml 2>/dev/null; then
        pass "containerd SystemdCgroup 활성화"
    else
        fail "containerd SystemdCgroup 설정 불완전"
    fi

    if swapon --noheadings --show 2>/dev/null | grep -q .; then
        fail "swap 활성 상태"
    else
        pass "swap 비활성 상태"
    fi
}
check_file_mode() {
    local path="$1"
    local expected="$2"
    local label="$3"
    local actual

    if [ ! -e "$path" ]; then
        fail "${label}: ${path} 없음"
        return
    fi

    actual=$(stat -c '%a' "$path" 2>/dev/null || echo "unknown")
    if [ "$actual" = "$expected" ]; then
        pass "${label}: 권한 ${actual}"
    else
        fail "${label}: 권한 ${actual}, 기대값 ${expected}"
    fi
}

manifest_has() {
    local file="$1"
    local pattern="$2"
    grep -Eq -- "$pattern" "$file" 2>/dev/null
}

check_static_pod_flags() {
    local api="/etc/kubernetes/manifests/kube-apiserver.yaml"
    local controller="/etc/kubernetes/manifests/kube-controller-manager.yaml"
    local scheduler="/etc/kubernetes/manifests/kube-scheduler.yaml"
    local etcd="/etc/kubernetes/manifests/etcd.yaml"

    if [ ! -f "$api" ]; then
        warn "Control Plane 정적 Pod 매니페스트가 없어 Worker 노드 검사로 진행합니다."
        return
    fi

    local api_checks=(
        '--anonymous-auth=false'
        '--authorization-mode=Node,RBAC'
        '--enable-admission-plugins=.*NodeRestriction'
        '--service-account-lookup=true'
        '--profiling=false'
        '--tls-min-version=VersionTLS12'
        '--audit-policy-file=/etc/kubernetes/security/audit-policy.yaml'
        '--audit-log-path=/var/log/kubernetes/audit/audit.log'
        '--encryption-provider-config=/etc/kubernetes/security/encryption-config.yaml'
        '--admission-control-config-file=/etc/kubernetes/security/pod-security-admission-config.yaml'
    )
    local pattern
    for pattern in "${api_checks[@]}"; do
        if manifest_has "$api" "$pattern"; then
            pass "kube-apiserver ${pattern}"
        else
            fail "kube-apiserver ${pattern} 누락"
        fi
    done

    if manifest_has "$controller" '--bind-address=127\.0\.0\.1' &&
       manifest_has "$controller" '--profiling=false' &&
       manifest_has "$controller" '--use-service-account-credentials=true'; then
        pass "kube-controller-manager 로컬 바인딩/프로파일링/ServiceAccount 설정"
    else
        fail "kube-controller-manager 보안 인자 불완전"
    fi

    if manifest_has "$scheduler" '--bind-address=127\.0\.0\.1' &&
       manifest_has "$scheduler" '--profiling=false'; then
        pass "kube-scheduler 로컬 바인딩 및 프로파일링 차단"
    else
        fail "kube-scheduler 보안 인자 불완전"
    fi

    if manifest_has "$etcd" '--client-cert-auth=true' &&
       manifest_has "$etcd" '--peer-client-cert-auth=true'; then
        pass "etcd 클라이언트/피어 인증서 인증"
    else
        fail "etcd 인증서 인증 인자 불완전"
    fi
}

check_kubelet() {
    local cfg="/var/lib/kubelet/config.yaml"
    if [ ! -f "$cfg" ]; then
        fail "kubelet 설정 파일 없음: ${cfg}"
        return
    fi

    if grep -A2 -E '^[[:space:]]+anonymous:' "$cfg" |
       grep -Eq 'enabled:[[:space:]]*false'; then
        pass "kubelet anonymous authentication 비활성화"
    else
        fail "kubelet anonymous authentication 설정 불완전"
    fi

    if grep -A2 -E '^[[:space:]]+webhook:' "$cfg" |
       grep -Eq 'enabled:[[:space:]]*true'; then
        pass "kubelet webhook authentication 활성화"
    else
        fail "kubelet webhook authentication 설정 불완전"
    fi

    if grep -Eq '^[[:space:]]*readOnlyPort:[[:space:]]*0' "$cfg"; then
        pass "kubelet read-only port 명시적 비활성화"
    elif ! grep -Eq '^[[:space:]]*readOnlyPort:' "$cfg" &&
         ! ss -lntH | grep -Eq '[[:space:]][^[:space:]]*:10255[[:space:]]'; then
        pass "kubelet read-only port 기본 비활성화 및 10255 미수신"
    else
        fail "kubelet read-only port가 안전하게 비활성화되지 않음"
    fi

    local checks=(
        '^[[:space:]]*mode:[[:space:]]*Webhook'
        '^[[:space:]]*protectKernelDefaults:[[:space:]]*true'
        '^[[:space:]]*rotateCertificates:[[:space:]]*true'
        '^[[:space:]]*serverTLSBootstrap:[[:space:]]*true'
        '^[[:space:]]*tlsMinVersion:[[:space:]]*VersionTLS12'
        '^[[:space:]]*seccompDefault:[[:space:]]*true'
    )
    local pattern
    for pattern in "${checks[@]}"; do
        if grep -Eq "$pattern" "$cfg"; then
            pass "kubelet 설정: ${pattern}"
        else
            fail "kubelet 설정 누락: ${pattern}"
        fi
    done
}

check_encryption() {
    local cfg="/etc/kubernetes/security/encryption-config.yaml"
    check_file_mode "$cfg" "600" "EncryptionConfiguration"

    if [ -f "$cfg" ] &&
       grep -q 'aescbc:' "$cfg" &&
       grep -q 'identity:' "$cfg"; then
        pass "Secret 암호화 provider와 복호화 fallback 구성"
    else
        fail "Secret 암호화 provider 구성 불완전"
    fi
}

check_audit_and_psa() {
    check_file_mode "/etc/kubernetes/security/audit-policy.yaml" "600" "Audit Policy"
    check_file_mode "/etc/kubernetes/security/pod-security-admission-config.yaml" "600" "PSA 설정"

    if [ -d /var/log/kubernetes/audit ]; then
        local mode
        mode=$(stat -c '%a' /var/log/kubernetes/audit)
        if [ "$mode" = "700" ]; then
            pass "감사 로그 디렉토리 권한 700"
        else
            fail "감사 로그 디렉토리 권한 ${mode}, 기대값 700"
        fi
    else
        fail "감사 로그 디렉토리 없음"
    fi
}

check_kubeconfigs() {
    local file
    for file in \
        /etc/kubernetes/admin.conf \
        /etc/kubernetes/controller-manager.conf \
        /etc/kubernetes/scheduler.conf \
        /etc/kubernetes/kubelet.conf; do
        [ -f "$file" ] || continue
        check_file_mode "$file" "600" "kubeconfig"
    done
}

check_sensitive_files() {
    local path owner mode
    local control_plane_files=(
        /etc/kubernetes/manifests/kube-apiserver.yaml
        /etc/kubernetes/manifests/kube-controller-manager.yaml
        /etc/kubernetes/manifests/kube-scheduler.yaml
        /etc/kubernetes/manifests/etcd.yaml
    )

    for path in "${control_plane_files[@]}"; do
        [ -f "$path" ] || continue
        check_file_mode "$path" "600" "정적 Pod 매니페스트"
    done

    if [ -d /var/lib/etcd ]; then
        mode=$(stat -c '%a' /var/lib/etcd)
        owner=$(stat -c '%U:%G' /var/lib/etcd)
        if [ "$mode" = "700" ] && [ "$owner" = "root:root" ]; then
            pass "etcd 데이터 디렉토리 권한과 소유자"
        else
            fail "etcd 데이터 디렉토리: ${owner} ${mode}, 기대값 root:root 700"
        fi
    fi

    if [ -d /etc/kubernetes/pki ]; then
        while IFS= read -r -d '' path; do
            mode=$(stat -c '%a' "$path")
            owner=$(stat -c '%U:%G' "$path")
            if { [ "$mode" = "600" ] || [ "$mode" = "400" ]; } &&
               [ "$owner" = "root:root" ]; then
                pass "PKI 개인키 보호: ${path}"
            else
                fail "PKI 개인키 권한: ${path} ${owner} ${mode}"
            fi
        done < <(find /etc/kubernetes/pki -type f -name '*.key' -print0)
    fi
}

check_cluster_state() {
    if ! command -v kubectl >/dev/null 2>&1; then
        warn "kubectl 미설치로 클러스터 상태 검사를 건너뜁니다."
        return
    fi

    local kubeconfig="/etc/kubernetes/admin.conf"
    if [ ! -f "$kubeconfig" ]; then
        warn "Worker 노드에서는 PSA Namespace/CSR 검사를 건너뜁니다."
        return
    fi

    if KUBECONFIG="$kubeconfig" kubectl get --raw='/readyz' >/dev/null 2>&1; then
        pass "kube-apiserver readyz"
    else
        fail "kube-apiserver readyz 실패"
    fi

    local pending
    pending=$(KUBECONFIG="$kubeconfig" kubectl get csr \
        --no-headers 2>/dev/null | awk '$NF == "Pending" {count++} END {print count+0}')
    if [ "$pending" -gt 0 ]; then
        warn "승인 대기 CSR ${pending}개. 요청자와 SAN을 검증한 후 개별 승인하십시오."
    else
        pass "승인 대기 CSR 없음"
    fi

    if KUBECONFIG="$kubeconfig" kubectl get namespace default \
        -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' \
        2>/dev/null | grep -qx 'baseline'; then
        pass "default Namespace PSA enforce=baseline"
    else
        warn "default Namespace PSA enforce=baseline 레이블 없음"
    fi
}

check_certificates() {
    if command -v kubeadm >/dev/null 2>&1 &&
       [ -f /etc/kubernetes/admin.conf ]; then
        if kubeadm certs check-expiration >/dev/null 2>&1; then
            pass "kubeadm 인증서 만료 상태 조회 성공"
        else
            warn "kubeadm 인증서 만료 상태 조회 실패"
        fi
    fi
}

main() {
    check_root
    echo -e "${CYAN}Kubernetes 보안 기준 점검${NC}"
    echo "점검은 읽기 전용이며 클러스터 설정을 변경하지 않습니다."
    echo ""

    check_ubuntu_host
    check_static_pod_flags
    check_kubelet
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        check_encryption
        check_audit_and_psa
    else
        warn "Worker 노드에서는 Control Plane 감사/암호화 파일 검사를 건너뜁니다."
    fi
    check_kubeconfigs
    check_sensitive_files
    check_cluster_state
    check_certificates

    echo ""
    echo "PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}"
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
