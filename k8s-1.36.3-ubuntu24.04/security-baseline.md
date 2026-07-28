# Kubernetes v1.36.3 보안 기준과 잔여 위험

## 1. 기준

이 문서는 `K8s취약점_점검_가이드.pdf`의 Master 17개 및 Worker 7개 점검 영역을 신규 설치 기본값에 반영한 결과를 설명합니다. 제품 버전은 Kubernetes `v1.36.3`이며, kubeadm 설정 API는 `v1beta4`입니다.

이 패키지는 점검 가이드 준수의 기술적 출발점입니다. 애플리케이션 RBAC, NetworkPolicy, 공급망 서명과 같은 환경별 통제까지 자동으로 충족한다는 뜻은 아닙니다.

## 2. 점검 항목 대응

| 영역 | 설치 기본값 | 검증 위치 |
| --- | --- | --- |
| 호스트 보안 | AppArmor와 UFW 활성, swap 비활성, systemd cgroup | `security_audit.sh` |
| API 익명 접근 | `anonymous-auth=false` | kube-apiserver manifest |
| API 인가 | `authorization-mode=Node,RBAC` | kube-apiserver manifest |
| Admission | `NodeRestriction`, Pod Security Admission | API 인자와 PSA 설정 |
| ServiceAccount 검증 | `service-account-lookup=true` | kube-apiserver manifest |
| API profiling | `profiling=false` | kube-apiserver manifest |
| API TLS | TLS 1.2 이상, 제한된 cipher suite | kube-apiserver manifest |
| 감사 로그 | 정책 파일, 로그 경로, 30일/10개/100MiB 회전 | API 인자와 로그 경로 |
| etcd 저장 암호화 | Secret/ConfigMap AES-CBC, identity fallback | EncryptionConfiguration |
| etcd 인증 | client/peer certificate auth | etcd manifest |
| controller-manager | localhost bind, profiling 차단, SA credential | static Pod manifest |
| scheduler | localhost bind, profiling 차단 | static Pod manifest |
| kubelet 익명 접근 | 비활성화 | kubelet config |
| kubelet 인증·인가 | X.509/Webhook 및 Webhook authorization | kubelet config |
| kubelet read-only port | `0` | kubelet config |
| kubelet kernel 보호 | `protectKernelDefaults=true`와 선행 sysctl | kubelet config/host |
| kubelet 인증서 | client rotation과 serving bootstrap | kubelet config/CSR |
| kubelet TLS | TLS 1.2 이상, 제한된 cipher suite | kubelet config |
| seccomp | kubelet 기본 seccomp 활성화 | kubelet config |
| kubeconfig 권한 | root 소유 `0600` | 파일 권한 |
| cluster-admin 배포 | 사용자 홈 복사 기본 거부 | 설치 입력과 marker |
| 자산 무결성 | SHA-256 불일치 시 설치 중단 | `SHA256SUMS` |

## 3. 의도적으로 자동화하지 않은 항목

### 3.1 Kubelet Serving CSR 승인

CSR을 이름만 보고 일괄 승인하면 위조 노드가 serving certificate를 얻을 수 있습니다. 패키지는 CSR 자동 승인을 하지 않습니다. 노드 identity와 SAN을 확인한 후 개별 승인해야 합니다.

### 3.2 기존 클러스터 보안 설정 덮어쓰기

기존 API server에 암호화 provider를 단번에 적용하거나 키를 바꾸면 읽기 불능 또는 롤백 불능 상황이 생길 수 있습니다. 새 설치만 자동 구성하고 기존 클러스터는 감지 즉시 중단합니다.

### 3.3 iptables 전체 초기화

호스트의 다른 서비스 방화벽까지 제거할 수 있으므로 reset 스크립트는 전체 flush를 수행하지 않습니다.

## 4. 남아 있는 운영 위험

### 4.1 버전과 CVE

`v1.36.3`은 이 패키지 작성 시점의 최신 보안 패치 기준입니다. 이후 patch release 또는 보안 공지가 나오면 자산을 다시 수집하고 단계적으로 업그레이드해야 합니다. 버전 고정만으로 미래 CVE가 해결되지는 않습니다.

### 4.2 RBAC 최소 권한

Kubernetes 기본 시스템 RBAC은 적용하지만, 배포되는 각 서비스의 ClusterRole과 binding 최소화는 별도 검토가 필요합니다. `cluster-admin` binding을 정기 점검해야 합니다.

### 4.3 NetworkPolicy

Calico 설치만으로 workload 간 통신이 자동 차단되지는 않습니다. Namespace별 default-deny 정책과 DNS, ingress, egress 허용 정책을 애플리케이션 설계에 맞게 추가해야 합니다.

### 4.4 이미지 공급망

`SHA256SUMS`는 반입 중 변조를 탐지하지만 upstream publisher 신뢰와 이미지 취약점까지 증명하지 않습니다. 외부망 수집 구역에서 SBOM, signature, CVE scan 결과를 함께 승인하는 절차가 필요합니다.

### 4.5 EncryptionConfiguration 백업

`encryption-config.yaml`을 잃으면 etcd의 암호화된 Secret과 ConfigMap을 복호화하지 못합니다. 파일은 일반 백업과 분리된 보안 저장소에 백업하고 접근을 감사해야 합니다.

### 4.6 Pod Security Standards

cluster 기본 enforce는 `baseline`, audit/warn은 `restricted`입니다. 시스템 Namespace는 명시적으로 면제됩니다. 업무 Namespace는 검증 후 `restricted` enforce로 단계적으로 올려야 합니다.

## 5. 정기 점검

다음 명령을 설치 직후와 정기 점검 시 실행합니다.

```bash
sudo ./scripts/security_audit.sh
sudo kubeadm certs check-expiration
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl auth can-i --list
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr
```

점검 결과는 `PASS`, `WARN`, `FAIL`로 구분됩니다. `WARN`은 자동 승인 대상이 아니며 운영 증적과 함께 판단해야 합니다.
